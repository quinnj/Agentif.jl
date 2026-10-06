isdefined(@__MODULE__, :durable_fixture) || include("durable_fixtures.jl")
using Tempus, LocalSearch

function kernel_task(h,c,p,key;owner=nothing,background=false,kind="tool")
    Claw._transition!(h) do db,seq
        Claw._task_create!(db,seq,c.id,kind,key;owner,background,input=Dict("profile"=>p.id),checkpoint=Dict("phase"=>"execute"))
    end
end

@testset "rollback, commit uncertainty and fenced adoption" begin
    mktempdir() do dir
        cut=Ref(:none)
        fault=(point,h)->point==cut[] && error("injected transition fault")
        path=joinpath(dir,"kernel.sqlite")
        h,c,p=durable_fixture(path;fault)
        original=Claw.snapshot(h,c).seq
        cut[]=:before_probe
        @test_throws ErrorException Claw._transition!(h;point=:probe) do db,seq
            Claw._exec!(db,"INSERT INTO claw_agent_data(key,value,created_at,updated_at) VALUES('rollback','v',0,0)")
        end
        @test h.state==:open
        @test Claw.snapshot(h,c).seq==original
        @test Claw._dread(db->Claw._done(db,"SELECT value FROM claw_agent_data WHERE key='rollback'"),h)===nothing
        cut[]=:after_probe
        @test_throws ErrorException Claw._transition!(h;point=:probe) do db,seq
            Claw._exec!(db,"INSERT INTO claw_agent_data(key,value,created_at,updated_at) VALUES('committed','v',0,0)")
        end
        @test h.state==:poisoned
        @test_throws Claw.HarnessPoisoned Claw.submit!(h,c,"rejected";request_id="poison")
        Claw.close_harness!(h)
        h,c,p=durable_fixture(path)
        try
            @test Claw._dread(db->Claw._done(db,"SELECT value FROM claw_agent_data WHERE key='committed'"),h).value=="v"
            id=kernel_task(h,c,p,"fence")
            t=Claw._task_row(h,id);ctx,_=Claw._reserve!(h,t)
            Claw.report_progress!(ctx,Dict("phase"=>"one"))
            saved_revision=ctx.revision[]
            Claw._dread(h) do db
                Claw._exec!(db,"UPDATE claw_tasks SET token='replacement',revision=revision+1 WHERE id=?",(id,))
            end
            ctx.last_progress[]=-Inf # the next report is written, so it checks the fence
            @test_throws Claw.StaleInvocation Claw.report_progress!(ctx,"stale token")
            @test Claw.inspect_task(h,id).revision==saved_revision+1
            other=kernel_task(h,c,p,"epoch")
            next,_=Claw._reserve!(h,Claw._task_row(h,other))
            Claw._dread(db->Claw._advance_owner!(db),h)
            next.last_progress[]=-Inf
            @test_throws Claw.StaleInvocation Claw.report_progress!(next,"stale owner")
            @test_throws Claw.StaleInvocation Claw._verify_invocation!(next)
        finally
            Claw.close_harness!(h)
        end
    end
end

@testset "owned drains, join policies, cycles and background cancellation" begin
    mktempdir() do dir
        h,c,p=durable_fixture(joinpath(dir,"ownership.sqlite"))
        try
            parent=kernel_task(h,c,p,"parent")
            child=kernel_task(h,c,p,"child";owner=parent)
            background=kernel_task(h,c,p,"background";owner=parent,background=true)
            Claw._transition!(h) do db,seq
                Claw._finish_task!(db,Claw._done(db,"SELECT * FROM claw_tasks WHERE id=?",(parent,)),Dict("status"=>"completed"))
            end
            @test Claw.inspect_task(h,parent).status=="completing"
            Claw._transition!(h) do db,seq
                Claw._finish_task!(db,Claw._done(db,"SELECT * FROM claw_tasks WHERE id=?",(child,)),Dict("status"=>"completed"))
                Claw._reconcile_ownership!(db,h,seq)
            end
            @test Claw.inspect_task(h,parent).status=="terminal"
            @test Claw.inspect_task(h,background).status=="pending"
            a=kernel_task(h,c,p,"a");b=kernel_task(h,c,p,"b")
            Claw._transition!((db,seq)->Claw._wait_tasks!(db,a,[b]),h)
            @test_throws ArgumentError Claw._transition!((db,seq)->Claw._wait_tasks!(db,b,[a]),h)
            nested=kernel_task(h,c,p,"nested";owner=b)
            @test_throws ArgumentError Claw._transition!((db,seq)->Claw._wait_tasks!(db,nested,[b]),h)
            @test_throws ArgumentError Claw._transition!((db,seq)->Claw._wait_tasks!(db,b,[a],"failFast"),h)
            fast=kernel_task(h,c,p,"fast")
            bad=kernel_task(h,c,p,"bad";owner=fast);sibling=kernel_task(h,c,p,"sibling";owner=fast)
            Claw._transition!(h) do db,seq
                Claw._wait_tasks!(db,fast,[bad,sibling],"failFast")
                Claw._finish_task!(db,Claw._done(db,"SELECT * FROM claw_tasks WHERE id=?",(bad,)),Dict("status"=>"failed"))
                Claw._reconcile_ownership!(db,h,seq)
            end
            @test Claw.inspect_task(h,sibling).cancel==1
            Claw._transition!((db,seq)->Claw._reconcile_ownership!(db,h,seq),h)
            @test Claw.inspect_task(h,sibling).status=="terminal"
            @test Claw.inspect_task(h,fast).status=="pending"
            Claw.abort_conversation!(h,c)
            @test Claw.inspect_task(h,background).cancel==0
            Claw.abort_conversation!(h,c;include_background=true)
            @test Claw.inspect_task(h,background).cancel==1
        finally
            Claw.close_harness!(h)
        end
    end
end

@testset "operator codec migration and immutable effective configuration" begin
    mktempdir() do dir
        h,c,p=durable_fixture(joinpath(dir,"codec.sqlite"))
        try
            id=kernel_task(h,c,p,"unknown-codec";kind="filter")
            Claw._dread(h) do db
                Claw._exec!(db,"UPDATE claw_tasks SET version=2,codec=2 WHERE id=?",(id,))
            end
            t=Claw._task_row(h,id)
            @test occursin("unsupported",last(Claw._eligibility(h,t)))
            @test_throws Claw.StaleInvocation Claw.migrate_task_checkpoint!((a,b)->(a,b),h,id;
                expected_revision=t.revision+1,from_version=2,from_codec=2,note="operator reviewed codec")
            Claw.migrate_task_checkpoint!((a,b)->(a,b),h,id;expected_revision=t.revision,from_version=2,from_codec=2,note="operator reviewed codec")
            @test Claw.inspect_task(h,id).codec==1
            @test last(Claw._eligibility(h,Claw._task_row(h,id)))===nothing
            source=Agentif.Agent(;model=durable_model(),prompt="changed",apikey="secret-test-key",http_kw=(;readtimeout=9,headers=Dict("Authorization"=>"secret-test-key","Accept"=>"application/json")))
            second=Claw.register_profile!(h,source)
            @test p.id!=second.id
            stored=Claw._dread(db->Claw._done(db,"SELECT payload FROM claw_agent_profiles WHERE id=?",(second.id,)).payload,h)
            @test !occursin("secret-test-key",stored)
            @test JSON.parse(stored)["http_options"]["readtimeout"]==9
            @test JSON.parse(stored)["model"]["maxTokens"]==1000
            delete!(h.agents,p.id)
            @test occursin("credentials unavailable",last(Claw._resolve_profile(h,p.id)))
            @test sizeof(Claw._bounded_json(Dict("text"=>repeat("🦊\"",10000)),128))<=128
            @test JSON.parse(Claw._bounded_json(Dict("text"=>repeat("🦊\"",10000)),128))["truncated"]
        finally
            Claw.close_harness!(h)
        end
    end
end

@testset "shared migrations, WAL backup and downgrade rehearsal" begin
    for version in 1:6
        mktempdir() do dir
            path=joinpath(dir,"old.sqlite");backup=joinpath(dir,"before.sqlite")
            db=SQLite.DB(path)
            try
                SQLite.execute(db,"CREATE TABLE claw_event_handlers(id TEXT PRIMARY KEY,prompt TEXT NOT NULL,channel_id TEXT)")
                SQLite.execute(db,"INSERT INTO claw_event_handlers VALUES('historical','original prompt',NULL)")
                Agentif.init_sqlite_session_schema!(db)
                entry=Agentif.SessionEntry(;id="kept",messages=[Agentif.UserMessage("historical memory")])
                SQLite.execute(db,"BEGIN IMMEDIATE")
                Agentif.append_session_batch!(db,"old",[entry])
                SQLite.execute(db,"COMMIT")
                for v in 2:version;Claw.CLAW_MIGRATIONS[v](db);end
                if version>=2
                    payload=JSON.json(Dict("channel_id"=>"old-channel","content"=>"queued","extra"=>Dict()))
                    Claw._exec!(db,"INSERT INTO claw_events(id,dedup_key,source,name,payload,status,lane,created_at) VALUES(41,'old-key','test','old-event',?,'pending','old-lane',1)",(payload,))
                    version==6 && SQLite.execute(db,"UPDATE claw_events SET batch=41")
                end
                Claw._set_user_version!(db,version)
            finally
                close(db)
            end
            h=Claw.open_harness(path;backup_path=backup,durability=:acknowledged_write)
            try
                @test Claw._dread(Claw._get_user_version,h)==Claw.CLAW_SCHEMA_VERSION
                @test Claw._dread(db->Claw._scalar(db,"PRAGMA synchronous"),h)==2
                @test Claw._dread(db->Claw._done(db,"SELECT trust FROM claw_event_handlers WHERE id='historical'"),h).trust=="owner"
                @test Agentif.get_entry(h.history,"kept")!==nothing
                @test Claw._dread(db->Claw._scalar(db,"SELECT COUNT(*) FROM claw_tool_executions"),h)==0
                @test Claw._dread(db->Claw._scalar(db,"SELECT COUNT(*) FROM claw_conversations WHERE branch_id='old'"),h)==1
                @test isempty(Claw._dread(db->Claw._drows(db,"PRAGMA foreign_key_check"),h))
                if version>=2
                    row=Claw._dread(db->Claw._done(db,"SELECT * FROM claw_events WHERE id=41"),h)
                    @test row.dedup_key=="old-key"
                    @test version==6 ? row.batch==41 : ismissing(row.batch)
                end
            finally
                Claw.close_harness!(h)
            end
            prior=SQLite.DB(backup)
            try
                @test Claw._get_user_version(prior)==version
                @test Claw._done(prior,"SELECT entry_id FROM session_entries WHERE entry_id='kept'")!==nothing
                @test Claw._done(prior,"SELECT name FROM sqlite_master WHERE name='claw_tasks'")===nothing
            finally
                close(prior)
            end
            reopened=Claw.open_harness(path)
            @test Agentif.get_branch_leaf(reopened.history,"old")=="kept"
            Claw.close_harness!(reopened)
        end
    end
    mktempdir() do dir
        future=joinpath(dir,"future.sqlite");db=SQLite.DB(future)
        SQLite.execute(db,"PRAGMA user_version=999");close(db)
        @test_throws ErrorException Claw.open_harness(future)
        db=SQLite.DB(future)
        @test isempty(Claw._drows(db,"SELECT name FROM sqlite_master"))
        close(db)
        corrupt=joinpath(dir,"incompatible.sqlite");db=SQLite.DB(corrupt)
        SQLite.execute(db,"CREATE TABLE session_entries(wrong TEXT)");close(db)
        @test_throws ErrorException Claw.open_harness(corrupt)
        db=SQLite.DB(corrupt)
        @test Claw._done(db,"SELECT name FROM sqlite_master WHERE name='claw_events'")===nothing
        close(db)
    end
end
