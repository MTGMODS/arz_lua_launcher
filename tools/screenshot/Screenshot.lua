script_name('MTG Screenshot')
script_author('MTG MODS')
script_version('1.0')
local encoding = require('encoding')
encoding.default = 'CP1251'
local u8 = encoding.UTF8
local busy = false

local function message(text)
    sampAddChatMessage(u8:decode('[Screenshot] {FFFFFF}' .. text), -1)
end

function main()
    repeat wait(100) until isSampAvailable()
    sampRegisterChatCommand('screenshot', function()
        if busy then message('Дождитесь сохранения предыдущего скриншота.'); return end
        local loaded, screenshot = pcall(require, 'android.screenshot')
        if not loaded then
            print('[Screenshot] ' .. tostring(screenshot))
            message('Не найдена библиотека скриншотов. Установите папку lib из архива в neomloader.')
            return
        end
        busy = true
        lua_thread.create(function()
            local ok, reason = screenshot.save()
            busy = false
            if ok then message('Скриншот сохранён в Галерею: Pictures/Arizona Helper.')
            else message(reason or 'Не удалось сохранить скриншот.') end
        end)
    end)
    wait(-1)
end
