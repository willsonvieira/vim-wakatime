" ============================================================================
" File:        wakatime.vim
" Description: Automatic time tracking for Vim.
" Maintainer:  WakaTime <support@wakatime.com>
" License:     BSD, see LICENSE.txt for more details.
" Website:     https://wakatime.com/
" ============================================================================

let s:VERSION = '4.0.15'


" Init {{{

    " Check Vim version
    if v:version < 700
        echoerr "This plugin requires vim >= 7."
        finish
    endif

    " Use constants for truthy check to improve readability
    let s:true = 1
    let s:false = 0

    " Only load plugin once
    if exists("g:loaded_wakatime")
        finish
    endif
    let g:loaded_wakatime = s:true

    " Backup & Override cpoptions
    let s:old_cpo = &cpo
    set cpo&vim

    " Script Globals
    let s:home = expand("$WAKATIME_HOME")
    if s:home == '$WAKATIME_HOME'
        let s:home = expand("$HOME")
    endif
    let s:cli_location = expand("<sfile>:p:h") . '/packages/wakatime/cli.py'
    let s:config_file = s:home . '/.wakatime.cfg'
    let s:default_configs = ['[settings]', 'debug = false', 'hidefilenames = false', 'ignore =', '    COMMIT_EDITMSG$', '    PULLREQ_EDITMSG$', '    MERGE_MSG$', '    TAG_EDITMSG$']
    let s:data_file = s:home . '/.wakatime.data'
    let s:config_file_already_setup = s:false
    let s:debug_mode_already_setup = s:false
    let s:is_debug_mode_on = s:false
    let s:local_cache_expire = 10  " seconds between reading s:data_file
    let s:last_heartbeat = [0, 0, '']

    " For backwards compatibility, rename wakatime.conf to wakatime.cfg
    if !filereadable(s:config_file)
        if filereadable(expand("$HOME/.wakatime"))
            exec "silent !mv" expand("$HOME/.wakatime") expand("$HOME/.wakatime.conf")
        endif
        if filereadable(expand("$HOME/.wakatime.conf"))
            if !filereadable(s:config_file)
                let contents = ['[settings]'] + readfile(expand("$HOME/.wakatime.conf"), '')
                call writefile(contents, s:config_file)
                call delete(expand("$HOME/.wakatime.conf"))
            endif
        endif
    endif

    " Set default python binary location
    if !exists("g:wakatime_PythonBinary")
        let g:wakatime_PythonBinary = 'python'
    endif

    " Set default heartbeat frequency in minutes
    if !exists("g:wakatime_HeartbeatFrequency")
        let g:wakatime_HeartbeatFrequency = 2
    endif

" }}}


" Function Definitions {{{

    function! s:StripWhitespace(str)
        return substitute(a:str, '^\s*\(.\{-}\)\s*$', '\1', '')
    endfunction

    function! s:SetupConfigFile()
        if !s:config_file_already_setup

            " Create config file if does not exist
            if !filereadable(s:config_file)
                call writefile(s:default_configs, s:config_file)
            endif

            " Make sure config file has api_key
            let found_api_key = s:false
            if s:GetIniSetting('settings', 'api_key') != '' || s:GetIniSetting('settings', 'apikey') != ''
                let found_api_key = s:true
            endif
            if !found_api_key
                call s:PromptForApiKey()
                echo "[WakaTime] Setup complete! Visit https://wakatime.com to view your coding activity."
            endif

            let s:config_file_already_setup = s:true
        endif
    endfunction

    function! s:SetupDebugMode()
        if !s:debug_mode_already_setup
            if s:GetIniSetting('settings', 'debug') == 'true'
                let s:is_debug_mode_on = s:true
            else
                let s:is_debug_mode_on = s:false
            endif
            let s:debug_mode_already_setup = s:true
        endif
    endfunction

    function! s:GetIniSetting(section, key)
        if !filereadable(s:config_file)
            return ''
        endif
        let lines = readfile(s:config_file)
        let currentSection = ''
        for line in lines
            let line = s:StripWhitespace(line)
            if matchstr(line, '^\[') != '' && matchstr(line, '\]$') != ''
                let currentSection = substitute(line, '^\[\(.\{-}\)\]$', '\1', '')
            else
                if currentSection == a:section
                    let group = split(line, '=')
                    if len(group) == 2 && s:StripWhitespace(group[0]) == a:key
                        return s:StripWhitespace(group[1])
                    endif
                endif
            endif
        endfor
        return ''
    endfunction

    function! s:SetIniSetting(section, key, val)
        let output = []
        let sectionFound = s:false
        let keyFound = s:false
        if filereadable(s:config_file)
            let lines = readfile(s:config_file)
            let currentSection = ''
            for line in lines
                let entry = s:StripWhitespace(line)
                if matchstr(entry, '^\[') != '' && matchstr(entry, '\]$') != ''
                    if currentSection == a:section && !keyFound
                        let output = output + [join([a:key, a:val], '=')]
                        let keyFound = s:true
                    endif
                    let currentSection = substitute(entry, '^\[\(.\{-}\)\]$', '\1', '')
                    let output = output + [line]
                    if currentSection == a:section
                        let sectionFound = s:true
                    endif
                else
                    if currentSection == a:section
                        let group = split(entry, '=')
                        if len(group) == 2 && s:StripWhitespace(group[0]) == a:key
                            let output = output + [join([a:key, a:val], '=')]
                            let keyFound = s:true
                        else
                            let output = output + [line]
                        endif
                    else
                        let output = output + [line]
                    endif
                endif
            endfor
        endif
        if !sectionFound
            let output = output + [printf('[%s]', a:section), join([a:key, a:val], '=')]
        else
            if !keyFound
                let output = output + [join([a:key, a:val], '=')]
            endif
        endif
        call writefile(output, s:config_file)
        return
    endfunction

    function! s:GetCurrentFile()
        return expand("%:p")
    endfunction

    function! s:EscapeArg(arg)
        return substitute(shellescape(a:arg), '!', '\\!', '')
    endfunction

    function! s:JoinArgs(args)
        let safeArgs = []
        for arg in a:args
            let safeArgs = safeArgs + [s:EscapeArg(arg)]
        endfor
        return join(safeArgs, ' ')
    endfunction

    function! s:IsWindows()
        if has('win32') || has('win64')
            return s:true
        endif
        return s:false
    endfunction

    function! s:SendHeartbeat(file, time, is_write, last)
        let file = a:file
        if file == ''
            let file = a:last[2]
        endif
        if file != ''
            let python_bin = g:wakatime_PythonBinary
            if s:IsWindows()
                if python_bin == 'python'
                    let python_bin = 'pythonw'
                endif
            endif
            let cmd = [python_bin, '-W', 'ignore', s:cli_location]
            let cmd = cmd + ['--entity', file]
            let cmd = cmd + ['--plugin', printf('vim/%d vim-wakatime/%s', v:version, s:VERSION)]
            if a:is_write
                let cmd = cmd + ['--write']
            endif
            if !empty(&syntax)
                let cmd = cmd + ['--language', &syntax]
            else
                if !empty(&filetype)
                    let cmd = cmd + ['--language', &filetype]
                endif
            endif
            let stdout = ''
            if s:IsWindows()
                if s:is_debug_mode_on
                    let stdout = system('(' . s:JoinArgs(cmd) . ')')
                else
                    exec 'silent !start /min cmd /c "' . s:JoinArgs(cmd) . '"'
                endif
            else
                if s:is_debug_mode_on
                    let stdout = system(s:JoinArgs(cmd))
                else
                    let stdout = system(s:JoinArgs(cmd) . ' &')
                endif
            endif
            call s:SetLastHeartbeat(a:time, a:time, file)
            if s:is_debug_mode_on && stdout != ''
                echo '[WakaTime] Heartbeat Command: ' . s:JoinArgs(cmd)
                echo '[WakaTime] Error: ' . stdout
            endif
        endif
    endfunction

    function! s:GetLastHeartbeat()
        if !s:last_heartbeat[0] || localtime() - s:last_heartbeat[0] > s:local_cache_expire
            if !filereadable(s:data_file)
                return [0, 0, '']
            endif
            let last = readfile(s:data_file, '', 3)
            if len(last) == 3
                let s:last_heartbeat = [s:last_heartbeat[0], last[1], last[2]]
            endif
        endif
        return s:last_heartbeat
    endfunction

    function! s:SetLastHeartbeatLocally(time, last_update, file)
        let s:last_heartbeat = [a:time, a:last_update, a:file]
    endfunction

    function! s:SetLastHeartbeat(time, last_update, file)
        call s:SetLastHeartbeatLocally(a:time, a:last_update, a:file)
        call writefile([substitute(printf('%d', a:time), ',', '.', ''), substitute(printf('%d', a:last_update), ',', '.', ''), a:file], s:data_file)
    endfunction

    function! s:EnoughTimePassed(now, last)
        let prev = a:last[1]
        if a:now - prev > g:wakatime_HeartbeatFrequency * 60
            return s:true
        endif
        return s:false
    endfunction

    function! s:PromptForApiKey()
        let api_key = s:false
        let api_key = s:GetIniSetting('settings', 'api_key')
        if api_key == ''
            let api_key = s:GetIniSetting('settings', 'apikey')
        endif

        let api_key = input("[WakaTime] Enter your wakatime.com api key: ", api_key)
        call s:SetIniSetting('settings', 'api_key', api_key)
    endfunction

    function! s:EnableDebugMode()
        call s:SetIniSetting('settings', 'debug', 'true')
        let s:is_debug_mode_on = s:true
    endfunction

    function! s:DisableDebugMode()
        call s:SetIniSetting('settings', 'debug', 'false')
        let s:is_debug_mode_on = s:false
    endfunction

" }}}


" Event Handlers {{{

    function! s:handleActivity(is_write)
        call s:SetupDebugMode()
        call s:SetupConfigFile()
        let file = s:GetCurrentFile()
        let now = localtime()
        let last = s:GetLastHeartbeat()
        if !empty(file) && file !~ "-MiniBufExplorer-" && file !~ "--NO NAME--" && file !~ "^term:"
            if a:is_write || s:EnoughTimePassed(now, last) || file != last[2]
                call s:SendHeartbeat(file, now, a:is_write, last)
            else
                if now - s:last_heartbeat[0] > s:local_cache_expire
                    call s:SetLastHeartbeatLocally(now, last[1], last[2])
                endif
            endif
        endif
    endfunction

" }}}


" Autocommand Events {{{

    augroup Wakatime
        autocmd!
        autocmd BufEnter * call s:handleActivity(s:false)
        autocmd VimEnter * call s:handleActivity(s:false)
        autocmd BufWritePost * call s:handleActivity(s:true)
        autocmd CursorMoved,CursorMovedI * call s:handleActivity(s:false)
    augroup END

" }}}


" Plugin Commands {{{

    :command -nargs=0 WakaTimeApiKey call s:PromptForApiKey()
    :command -nargs=0 WakaTimeDebugEnable call s:EnableDebugMode()
    :command -nargs=0 WakaTimeDebugDisable call s:DisableDebugMode()

" }}}


" Restore cpoptions
let &cpo = s:old_cpo
