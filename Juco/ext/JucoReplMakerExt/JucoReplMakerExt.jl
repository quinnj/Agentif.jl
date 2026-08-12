module JucoReplMakerExt

using Juco, ReplMaker, REPL
using REPL: LineEdit

# Tab-completion for `$skill-name` tokens in the juco> mode.
struct SkillCompletionProvider <: LineEdit.CompletionProvider
    skills::Vector{Juco.Skill}
end

function LineEdit.complete_line(c::SkillCompletionProvider, s::LineEdit.PromptState; hint::Bool = false)
    full = LineEdit.input_string(s)
    cursor = position(LineEdit.buffer(s))
    names, byterange, should = Juco.skill_completions(full, cursor, c.skills)
    completions = [LineEdit.NamedCompletion(n) for n in names]
    region = REPL.to_region(full, byterange)
    return completions, region, should
end

function Juco.repl_mode!(; db_path::AbstractString = Juco.DEFAULT_DB_PATH, start_key::Char = '}', kw...)
    st = Juco.mode_state(db_path)
    ReplMaker.initrepl(input -> Juco.mode_eval(st, input; kw...);
        prompt_text = "juco> ",
        prompt_color = :magenta,
        start_key = start_key,
        mode_name = :juco,
        valid_input_checker = Returns(true),
        completion_provider = SkillCompletionProvider(st.skills),
        startup_text = true)
    return nothing
end

end
