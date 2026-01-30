using Test, LLMTools, Agentif, JSON

@testset "Qmd Tools" begin
    
    @testset "qmd_list_collections" begin
        result = LLMTools.qmd_list_collections()
        @test result["success"] == true
        @test haskey(result, "collections")
    end
    
    @testset "qmd_index_files validation" begin
        # Test with non-existent directory
        result = LLMTools.qmd_index_files("/nonexistent/path")
        @test result["success"] == false
        @test occursin("not found", lowercase(result["message"]))
    end
    
    @testset "qmd_search validation" begin
        # Test search without any collection
        LLMTools.QMD_CURRENT_COLLECTION[] = nothing
        result = LLMTools.qmd_search("test query")
        @test result["success"] == false
        @test occursin("no collection", lowercase(result["message"]))
    end
    
    @testset "Tool creation" begin
        # Create a temporary directory for testing
        mktempdir() do tmpdir
            index_tool = LLMTools.create_qmd_index_tool(tmpdir)
            @test index_tool isa Agentif.AgentTool
            @test index_tool.name == "qmd_index"
            
            search_tool = LLMTools.create_qmd_search_tool(tmpdir)
            @test search_tool isa Agentif.AgentTool
            @test search_tool.name == "qmd_search_tool"
        end
    end
    
end

println("✓ Qmd tools tests passed")
