module JucoReplMakerExt

using Juco, ReplMaker

function Juco.repl_mode!(; db_path::AbstractString = Juco.DEFAULT_DB_PATH, start_key::Char = '}', kw...)
    st = Juco.mode_state(db_path)
    ReplMaker.initrepl(input -> Juco.mode_eval(st, input; kw...);
        prompt_text = "juco> ",
        prompt_color = :magenta,
        start_key = start_key,
        mode_name = :juco,
        valid_input_checker = Returns(true),
        startup_text = true)
    return nothing
end

end
