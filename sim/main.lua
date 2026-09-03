io.stdout:setvbuf("no")

-- Entry point for the LÖVE-hosted sims (`love sim` / `lovec sim`).
--
--   lovec.exe sim                              → sim/run.lua
--   lovec.exe sim --gen-equity bench|anchors   short generator modes
--   lovec.exe sim --verify-realism [seed] [n]
--
-- LuaJIT makes these roughly twice as fast as the standalone interpreter.
-- But anything that runs for more than a couple of minutes has to use
-- `lua` directly instead: all of this happens inside love.load(), and a
-- LÖVE process that never reaches its event loop gets killed partway
-- through. A full equity generation is an hour and must NOT be run here
-- — see the header of sim/gen_preflop_equity.lua.
function love.load()
    local mode, rest = nil, {}
    for i = 1, #arg do
        local a = arg[i]
        if a == "--gen-equity" or a == "--verify-realism" then
            mode = a
            for k = i + 1, #arg do rest[#rest + 1] = arg[k] end
            break
        end
    end

    if mode then
        local cwd = love.filesystem.getWorkingDirectory() or "."
        package.path = package.path .. ";" .. cwd .. "/?.lua"
        if mode == "--gen-equity" then
            _G.GEN_EQUITY_ARGS = rest
            require("sim.gen_preflop_equity")
        else
            _G.VERIFY_REALISM_ARGS = rest
            require("sim.verify_showdown_realism")
        end
    else
        require("sim.run")
    end
    love.event.quit()
end
