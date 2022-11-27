"=================================== Jetpack ==================================
"Copyright (c) 2022 TANIGUCHI Masaya
"
"Permission is hereby granted, free of charge, to any person obtaining a copy
"of this software and associated documentation files (the "Software"), to deal
"in the Software without restriction, including without limitation the rights
"to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
"copies of the Software, and to permit persons to whom the Software is
"furnished to do so, subject to the following conditions:
"
"The above copyright notice and this permission notice shall be included in all
"copies or substantial portions of the Software.
"
"THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
"IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
"FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
"AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
"LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
"OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
"SOFTWARE.
"==============================================================================

if exists('g:loaded_jetpack')
  finish
endif
let g:loaded_jetpack = 1

let g:jetpack_njobs = get(g:, 'jetpack_njobs', 8)

let g:jetpack_ignore_patterns =
  \ get(g:, 'jetpack_ignore_patterns', [
  \   '[\/]doc[\/]tags*',
  \   '[\/]test[\/]*',
  \   '[\/][.ABCDEFGHIJKLMNOPQRSTUVWXYZ]*'
  \ ])

let g:jetpack_download_method =
  \ get(g:, 'jetpack_download_method', 'git')
  " curl: Use CURL to download
  " wget: Use Wget to download

let g:jetpack_copy_method =
  \ get(g:, 'jetpack_copy_method', 'system')
  " sytem    : cp/ xcopy
  " copy     : readfile and writefile
  " symlink  : fs_symlink (nvim only)
  " hardlink : fs_link (nvim only)

let s:cmds = {}
let s:maps = {}

let s:declared_packages = get(s:, 'packages', {})

let s:status = {
\   'pending': 'pending',
\   'skipped': 'skipped',
\   'installed': 'installed',
\   'installing': 'installing',
\   'updated': 'updated',
\   'updating': 'updating',
\   'switched': 'switched',
\   'merged': 'merged',
\   'copied': 'copied'
\ }

function! s:list_files(path) abort
  let files = readdir(a:path, { entry -> filereadable(a:path . '/' . entry) })
  let files = map(files, { _, entry -> a:path . '/' . entry })
  let dirs = readdir(a:path, { entry -> isdirectory(a:path . '/' . entry) })
  let dirs = map(dirs, { _, entry -> a:path . '/' . entry })
  for dir in dirs
    let files += s:list_files(dir)
  endfor
  return files
endfunction

function! s:check_ignorable(filename) abort
  return filter(copy(g:jetpack_ignore_patterns), { _, val -> a:filename =~# glob2regpat(val) }) != []
endfunction

function! s:make_progressbar(n) abort
  return '[' . join(map(range(0, 100, 3), {_, v -> v < a:n ? '=' : ' '}), '') . ']'
endfunction

function! s:jobstatus(job) abort
  if has('nvim')
    return jobwait([a:job], 0)[0] == -1 ? 'run' : 'dead'
  endif
  return job_status(a:job)
endfunction

function! s:jobcount(jobs) abort
  return len(filter(copy(a:jobs), { _, val -> s:jobstatus(val) ==# 'run' }))
endfunction

function! s:jobwait(jobs, njobs) abort
  let running = s:jobcount(a:jobs)
  while running > a:njobs
    let running = s:jobcount(a:jobs)
  endwhile
endfunction

" Original: https://github.com/lambdalisue/vital-Whisky/blob/90c71/autoload/vital/__vital__/System/Job/Vim.vim#L46
"  License: https://github.com/lambdalisue/vital-Whisky/blob/90c71/LICENSE
function! s:nvim_exit_cb(buf, cb, job, ...) abort
  let ch = job_getchannel(a:job)
  while ch_status(ch) ==# 'open' | sleep 1ms | endwhile
  while ch_status(ch) ==# 'buffered' | sleep 1ms | endwhile
  call a:cb(join(a:buf, "\n"))
endfunction

function! s:jobstart(cmd, cb) abort
  if has('nvim')
    let buf = []
    return jobstart(a:cmd, {
    \   'on_stdout': { _, data -> extend(buf, data) },
    \   'on_stderr': { _, data -> extend(buf, data) },
    \   'on_exit': { -> a:cb(join(buf, "\n")) }
    \ })
  else
    let buf = []
    return job_start(a:cmd, {
    \   'out_mode': 'raw',
    \   'out_cb': { _, data -> extend(buf, split(data, "\n")) },
    \   'err_mode': 'raw',
    \   'err_cb': { _, data -> extend(buf, split(data, "\n")) },
    \   'exit_cb': function('s:nvim_exit_cb', [buf, a:cb])
    \ })
  endif
endfunction

function! s:copy_dir(from, to) abort
  call mkdir(a:to, 'p')
  if g:jetpack_copy_method !=# 'system'
    for src in s:list_files(a:from)
      let dest = substitute(src, '\V' . escape(a:from, '\'), escape(a:to, '\'), '')
      call mkdir(fnamemodify(dest, ':p:h'), 'p')
      if g:jetpack_copy_method ==# 'copy'
        call writefile(readfile(src, 'b'), dest, 'b')
      elseif g:jetpack_copy_method ==# 'hardlink'
        call v:lua.vim.loop.fs_link(src, dest)
      elseif g:jetpack_copy_method ==# 'symlink'
        call v:lua.vim.loop.fs_symlink(src, dest)
      endif
    endfor
  elseif has('unix')
    call system(printf('cp -R %s/. %s', a:from, a:to))
  elseif has('win32')
    call system(printf('xcopy %s %s /E /Y', expand(a:from), expand(a:to)))
  endif
endfunction

function! s:initialize_buffer() abort
  execute 'silent! bdelete! ' . bufnr('JetpackStatus')
  40vnew +setlocal\ buftype=nofile\ nobuflisted\ nonumber\ norelativenumber\ signcolumn=no\ noswapfile\ nowrap JetpackStatus
  syntax clear
  syntax match jetpackProgress /^[a-z]*ing/
  syntax match jetpackComplete /^[a-z]*ed/
  syntax keyword jetpackSkipped ^skipped
  highlight def link jetpackProgress DiffChange
  highlight def link jetpackComplete DiffAdd
  highlight def link jetpackSkipped DiffDelete
  redraw
endfunction

function! s:show_progress(title) abort
  let buf = bufnr('JetpackStatus')
  call deletebufline(buf, 1, '$')
  let processed = len(filter(copy(s:declared_packages), { _, val -> val.status[-1] =~# 'ed' }))
  call setbufline(buf, 1, printf('%s (%d / %d)', a:title, processed, len(s:declared_packages)))
  call appendbufline(buf, '$', s:make_progressbar((0.0 + processed) / len(s:declared_packages) * 100))
  for [pkg_name, pkg] in items(s:declared_packages)
    call appendbufline(buf, '$', printf('%s %s', pkg.status[-1], pkg_name))
  endfor
  redraw
endfunction

function! s:show_result() abort
  let buf = bufnr('JetpackStatus')
  call deletebufline(buf, 1, '$')
  call setbufline(buf, 1, 'Result')
  call appendbufline(buf, '$', s:make_progressbar(100))
  for [pkg_name, pkg] in items(s:declared_packages)
    if index(pkg.status, s:status.installed) >= 0
      call appendbufline(buf, '$', printf('installed %s', pkg_name))
    elseif index(pkg.status, s:status.updated) >= 0
      call appendbufline(buf, '$', printf('updated %s', pkg_name))
    else
      call appendbufline(buf, '$', printf('skipped %s', pkg_name))
    endif
    let output = substitute(pkg.output, '\r\n\|\r', '\n', 'g')
    let output = substitute(output, '^From.\{-}\zs\n\s*', '/compare/', '')
    for line in split(output, '\n')
      call appendbufline(buf, '$', printf('  %s', line))
    endfor
  endfor
  redraw
endfunction

function! s:clean_plugins() abort
  if g:jetpack_download_method !=# 'git'
    return
  endif
  for [pkg_name, pkg] in items(s:declared_packages)
    if isdirectory(pkg.path)
      let branch = trim(system(printf('git -C %s rev-parse --abbrev-ref %s', pkg.path, pkg.commit)))
      if v:shell_error
        call delete(pkg.path, 'rf')
        continue
      endif
      if !empty(pkg.branch) && pkg.branch !=# branch
        call delete(pkg.path, 'rf')
        continue
      endif
      if !empty(pkg.tag) && pkg.tag !=# branch
        call delete(pkg.path, 'rf')
        continue
      endif
    endif
  endfor
endfunction

function! s:make_download_cmd(pkg) abort
  if g:jetpack_download_method ==# 'git'
    if isdirectory(a:pkg.path)
      return ['git', '-C', a:pkg.path, 'pull', '--rebase']
    else
      let cmd = ['git', 'clone']
      if a:pkg.commit ==# 'HEAD'
        call extend(cmd, ['--depth', '1', '--recursive'])
      endif
      if !empty(a:pkg.branch)
        call extend(cmd, ['-b', a:pkg.branch])
      endif
      if !empty(a:pkg.tag)
        call extend(cmd, ['-b', a:pkg.tag])
      endif
      call extend(cmd, [a:pkg.url, a:pkg.path])
      return cmd
    endif
  else
    if !empty(a:pkg.tag)
      let label = a:pkg.tag
    elseif !empty(a:pkg.branch)
      let label = a:pkg.branch
    else
      let label = a:pkg.commit
    endif
    if g:jetpack_download_method ==# 'curl'
      let download_cmd = 'curl -fsSL ' .  a:pkg.url . '/archive/' . label . '.tar.gz'
    elseif g:jetpack_download_method ==# 'wget'
      let download_cmd = 'wget -O - ' .  a:pkg.url . '/archive/' . label . '.tar.gz'
    else
      throw 'g:jetpack_download_method: ' . g:jetpack_download_method . ' is not a valid value'
    endif
    let extract_cmd = 'tar -zxf - -C ' . a:pkg.path . ' --strip-components 1'
    call delete(a:pkg.path, 'rf')
    if has('unix')
      return ['sh', '-c', download_cmd . ' | ' . extract_cmd]
    elseif has('win32')
      return ['cmd.exe', '/c' . download_cmd . ' | ' . extract_cmd]
    endif
  endif
endfunction

function! s:download_plugins() abort
  let jobs = []
  for [pkg_name, pkg] in items(s:declared_packages)
    call add(pkg.status, s:status.pending)
  endfor
  for [pkg_name, pkg] in items(s:declared_packages)
    if pkg.local
      continue
    endif
    call s:show_progress('Install Plugins')
    if isdirectory(pkg.path)
      if pkg.frozen
        call add(pkg.status, s:status.skipped)
        continue
      endif
      call add(pkg.status, s:status.updating)
      let status = s:status.updated
    else
      call add(pkg.status, s:status.installing)
      let status = s:status.installed
    endif
    let cmd = s:make_download_cmd(pkg)
    call mkdir(pkg.path, 'p')
    let job = s:jobstart(cmd, function({status, pkg, output -> [
    \   add(pkg.status, status),
    \   execute("let pkg.output = output")
    \ ]}, [status, pkg]))
    call add(jobs, job)
    call s:jobwait(jobs, g:jetpack_njobs)
  endfor
  call s:jobwait(jobs, 0)
endfunction

function! s:switch_plugins() abort
  if g:jetpack_download_method !=# 'git'
    return
  endif
  for [pkg_name, pkg] in items(s:declared_packages)
    call add(pkg.status, s:status.pending)
  endfor
  for [pkg_name, pkg] in items(s:declared_packages)
    call s:show_progress('Switch Plugins')
    if !isdirectory(pkg.path)
      call add(pkg.status, s:status.skipped)
      continue
    else
      call add(pkg.status, s:status.switched)
    endif
    call system(printf('git -C %s checkout %s', pkg.path, pkg.commit))
  endfor
endfunction

function! s:merge_plugins() abort
  for [pkg_name, pkg] in items(s:declared_packages)
    call add(pkg.status, s:status.pending)
  endfor

  let bundle = {}
  let unbundle = {}
  for [pkg_name, pkg] in items(s:declared_packages)
    if pkg.merged
      let bundle[pkg_name] = pkg
    else
      let unbundle[pkg_name] = pkg
    endif
  endfor

  " Delete old directories
  for dir in glob(s:optdir . '/*', '', 1)
    let pkg_name = fnamemodify(dir, ':t')
    if !has_key(s:declared_packages, pkg_name)
     \ || s:declared_packages[pkg_name].output !~# 'Already up to date.'
      call delete(dir, 'rf')
    endif
  endfor

  " Merge plugins if possible.
  let merged_files = []
  for [pkg_name, pkg] in items(bundle)
    call s:show_progress('Merge Plugins')
    let srcdir = pkg.path . '/' . pkg.rtp
    let files = map(s:list_files(srcdir), {_, file -> file[len(srcdir):]})
    let files = filter(files, { _, file -> !s:check_ignorable(file) })
    let conflicted = v:false
    for file in files
      for merged_file in merged_files
        let conflicted =
          \ file =~# '\V' . escape(merged_file, '\') ||
          \ merged_file =~# '\V' . escape(file, '\')
        if conflicted
          break
        endif
      endfor
      if conflicted
        break
      endif
    endfor
    if conflicted
      let unbundle[pkg_name] = pkg
      let pkg.merged = v:false
    else
      call extend(merged_files, files)
      call s:copy_dir(srcdir, s:optdir . '/_')
      call add(pkg.status, s:status.merged)
    endif
  endfor

  " Copy plugins.
  for [pkg_name, pkg] in items(unbundle)
    call s:show_progress('Copy Plugins')
    if !empty(pkg.dir)
      call add(pkg.status, s:status.skipped)
    else
      let srcdir = pkg.path . '/' . pkg.rtp
      let destdir = s:optdir . '/' . pkg_name
      if pkg.local
        if has('win32')
          call system(join(['cmd', '/C', 'mklink', '/J', shellescape(destdir), shellescape(pkg.url)]))
        else
          call system(join(['ln', '-sfn', shellescape(pkg.url), shellescape(destdir)]))
        endif
      else
        call s:copy_dir(srcdir, destdir)
      endif
      call add(pkg.status, s:status.copied)
    endif
  endfor

  call writefile([json_encode(s:declared_packages)], s:optdir . '/available_packages.json')
  let s:available_packages = s:declared_packages
endfunction

function! s:postupdate_plugins() abort
  silent! packadd _
  for [pkg_name, pkg] in items(s:declared_packages)
    if empty(pkg.do) || pkg.output =~# 'Already up to date.'
      continue
    endif
    let pwd = getcwd()
    if pkg.dir !=# ''
      call chdir(pkg.path)
    else
      call jetpack#load(pkg_name)
      call chdir(s:optdir . '/' . pkg_name)
    endif
    if type(pkg.do) == v:t_func
      call pkg.do()
    endif
    if type(pkg.do) != v:t_string
      continue
    endif
    if pkg.do =~# '^:'
      execute pkg.do
    else
      call system(pkg.do)
    endif
    call chdir(pwd)
  endfor
  for dir in glob(s:optdir . '/*/doc', '', 1)
    execute 'silent! helptags ' . dir
  endfor
endfunction

function! jetpack#sync() abort
  call s:initialize_buffer()
  call s:clean_plugins()
  call s:download_plugins()
  call s:switch_plugins()
  call s:merge_plugins()
  call s:show_result()
  call s:postupdate_plugins()
endfunction

" Original: https://github.com/junegunn/vim-plug/blob/e3001/plug.vim#L479-L529
"  License: MIT, https://raw.githubusercontent.com/junegunn/vim-plug/e3001/LICENSE
if has('win32')
  function! s:is_local_plug(repo)
    return a:repo =~? '^[a-z]:\|^[%~]'
  endfunction
else
  function! s:is_local_plug(repo)
    return a:repo[0] =~# '[/$~]'
  endfunction
endif

" If opt/do/dir/setup/config option is enabled,
" it should be placed isolated directory (not merged).
function! s:is_merged(pkg) abort
  if a:pkg.opt
    return v:false
  elseif a:pkg.do !=# ''
    return v:false
  elseif a:pkg.dir !=# ''
    return v:false
  elseif a:pkg.setup !=# ''
    return v:false
  elseif a:pkg.config !=# ''
    return v:false
  elseif a:pkg.local
    return v:false
  endif
  return v:true
endfunction

function! jetpack#add(plugin, ...) abort
  let opts = a:0 > 0 ? a:1 : {}
  let local = s:is_local_plug(a:plugin)
  let url = local ? expand(a:plugin) : (a:plugin !~# ':' ? 'https://github.com/' : '') . a:plugin
  let path = local ? expand(a:plugin) : get(opts, 'dir', s:srcdir . '/' .  substitute(url, 'https\?://', '', ''))
  let on = has_key(opts, 'on') ? (type(opts.on) ==# v:t_list ? opts.on : [opts.on]) : []
  let on = extend(on, has_key(opts, 'for') ? (type(opts.for) ==# v:t_list ? opts.for : [opts.for]) : [])
  let on = extend(on, has_key(opts, 'ft') ? (type(opts.ft) ==# v:t_list ? opts.ft : [opts.ft]) : [])
  let on = extend(on, has_key(opts, 'cmd') ? (type(opts.cmd) ==# v:t_list ? opts.cmd : [opts.cmd]) : [])
  let on = extend(on, has_key(opts, 'map') ? (type(opts.map) ==# v:t_list ? opts.map : [opts.map]) : [])
  let on = extend(on, has_key(opts, 'event') ? (type(opts.event) ==# v:t_list ? opts.event : [opts.event]) : [])
  let pkg  = {
  \   'url': url,
  \   'local': local,
  \   'branch': get(opts, 'branch', ''),
  \   'tag': get(opts, 'tag', ''),
  \   'commit': get(opts, 'commit', 'HEAD'),
  \   'rtp': get(opts, 'rtp', ''),
  \   'do': get(opts, 'do', get(opts, 'run', '')),
  \   'frozen': get(opts, 'frozen', v:false),
  \   'dir': get(opts, 'dir', ''),
  \   'on': on,
  \   'opt': !empty(on) || get(opts, 'opt'),
  \   'path': path,
  \   'status': [s:status.pending],
  \   'output': '',
  \   'setup': get(opts, 'setup', ''),
  \   'config': get(opts, 'config', ''),
  \ }
  let pkg.merged = s:is_merged(pkg)
  let s:declared_packages[get(opts, 'as', fnamemodify(a:plugin, ':t'))] = pkg
endfunction

function! jetpack#begin(...) abort
  let s:declared_packages = {}
  " In lua, passing nil and no argument are synonymous, but in practice, v:null is passed.
  if a:0 > 0 && a:1 != v:null
    let s:home = expand(a:1)
    execute 'set packpath^=' . s:home
    execute 'set runtimepath^=' . s:home
  elseif has('nvim')
    let s:home = stdpath('data') . '/' . 'site'
  elseif has('win32')
    let s:home = expand('~/vimfiles')
  else
    let s:home = expand('~/.vim')
  endif
  let s:optdir = s:home . '/pack/jetpack/opt'
  let s:srcdir = s:home . '/pack/jetpack/src'
  command! -nargs=+ -bar Jetpack call jetpack#add(<args>)
endfunction

" Not called during startup
function! jetpack#load(pkg_name) abort
  if !has_key(s:declared_packages, a:pkg_name)
    return v:false
  endif
  let pkg = s:declared_packages[a:pkg_name]
  execute pkg.setup
  execute 'silent! packadd' a:pkg_name
  execute pkg.config
  return v:true
endfunction

" Original: https://github.com/junegunn/vim-plug/blob/e3001/plug.vim#L683-L693
"  License: MIT, https://raw.githubusercontent.com/junegunn/vim-plug/e3001/LICENSE
function! s:load_map(map, names, with_prefix, prefix)
  for name in a:names
    call jetpack#load(name)
  endfor
  let extra = ''
  let code = getchar(0)
  while (code != 0 && code != 27)
    let extra .= nr2char(code)
    let code = getchar(0)
  endwhile
  if a:with_prefix
    let prefix = v:count ? v:count : ''
    let prefix .= '"'.v:register.a:prefix
    if mode(1) ==# 'no'
      if v:operator ==# 'c'
        let prefix = "\<Esc>" . prefix
      endif
      let prefix .= v:operator
    endif
    call feedkeys(prefix, 'n')
  endif
  call feedkeys(substitute(a:map, '^<Plug>', "\<Plug>", 'i') . extra)
endfunction

function! s:load_cmd(cmd, names, ...) abort
  execute printf('delcommand %s', a:cmd)
  for name in a:names
    call jetpack#load(name)
  endfor
  let args = a:0>0 ? join(a:000, ' ') : ''
  try
    execute printf('%s %s', a:cmd, args)
  catch /.*/
    echohl ErrorMsg
    echomsg v:exception
    echohl None
  endtry
endfunction

function! jetpack#end() abort
  let available_packages_file = s:optdir . '/available_packages.json'
  silent! let available_packages_text = join(readfile(available_packages_file))
  let s:available_packages = json_decode(available_packages_text)
  let s:available_packages = empty(s:available_packages) ? {} : s:available_packages

  delcommand Jetpack
  command! -bar JetpackSync call jetpack#sync()

  syntax off
  filetype plugin indent off

  augroup Jetpack
    autocmd!
  augroup END

  for [pkg_name, pkg] in items(s:declared_packages)
    if !empty(pkg.dir)
      let &runtimepath .= printf(',%s/%s', pkg.dir, pkg.rtp)
      continue
    endif
    if !pkg.opt
      execute pkg.setup
      execute 'silent! packadd!' pkg_name
      if pkg.config !=# ''
        execute printf('autocmd Jetpack User JetpackEnd %s', pkg.config)
      endif
      continue
    endif
    for it in pkg.on
      if it =~? '^<Plug>'
        let s:maps[it] = add(get(s:maps, it, []), pkg_name)
        execute printf('inoremap <silent> %s <C-\><C-O>:<C-U>call <SID>load_map(%s, %s, 0, "")<CR>', it, string(it), s:maps[it])
        execute printf('nnoremap <silent> %s :<C-U>call <SID>load_map(%s, %s, 1, "")<CR>', it, string(it), s:maps[it])
        execute printf('vnoremap <silent> %s :<C-U>call <SID>load_map(%s, %s, 1, "gv")<CR>', it, string(it), s:maps[it])
        execute printf('onoremap <silent> %s :<C-U>call <SID>load_map(%s, %s, 1, "")<CR>', it, string(it), s:maps[it])
      elseif exists('##'.substitute(it, ' .*', '', ''))
        let it .= (it =~? ' ' ? '' : ' *')
        execute printf('autocmd Jetpack %s ++once ++nested call jetpack#load(%s)', it, string(pkg_name))
      elseif substitute(it, '^:', '', '') =~# '^[A-Z]'
        let cmd = substitute(it, '^:', '', '')
        let s:cmds[cmd] = add(get(s:cmds, cmd, []), pkg_name)
        execute printf('command! -range -nargs=* %s :call <SID>load_cmd(%s, %s, <f-args>)', cmd, string(cmd), s:cmds[cmd])
      else
        execute printf('autocmd Jetpack FileType %s ++once ++nested call jetpack#load(%s)', it, string(pkg_name))
      endif
    endfor
    let event = substitute(pkg_name, '\W\+', '_', 'g')
    let event = substitute(event, '\(^\|_\)\(.\)', '\u\2', 'g')
    execute printf('autocmd Jetpack SourcePre **/pack/jetpack/opt/%s/* ++once ++nested doautocmd User Jetpack%sPre', pkg_name, event)
    execute printf('autocmd Jetpack SourcePost **/pack/jetpack/opt/%s/* ++once ++nested doautocmd User Jetpack%sPost', pkg_name, event)
    execute printf('autocmd Jetpack User Jetpack%sPre :', event)
    execute printf('autocmd Jetpack User Jetpack%sPost :', event)
  endfor
  silent! packadd! _

  autocmd Jetpack User JetpackEnd :
  doautocmd Jetpack User JetpackEnd

  syntax enable
  filetype plugin indent on
endfunction

function! jetpack#tap(name) abort
  return has_key(s:available_packages, a:name) ? v:true : v:false
endfunction

function! jetpack#names() abort
  return keys(s:declared_packages)
endfunction

function! jetpack#get(name) abort
  return get(s:declared_packages, a:name, {})
endfunction

if !has('nvim') | finish | endif
lua<<========================================
local Packer = {
  option = {},
  plugin = {},
}

Packer.init = function(opt)
  if opt.package_root then
    opt.package_root = string.gsub(vim.fn.fnamemodify(opt.package_root, ":h"), '\\', '/')
  end
  Packer.option = opt
end

local function ensure_fun(fun)
  if type(fun) == 'string' then
    return assert(loadstring(fun))
  else
    return fun
  end
end

local function use(plugin)
  if type(plugin) == 'string' then
    vim.fn['jetpack#add'](plugin)
  else
    local repo = table.remove(plugin, 1)
    if next(plugin) == nil then
      vim.fn['jetpack#add'](repo)
    else
      local name = plugin['as'] or string.gsub(repo, '.*/', '')
      Packer.plugin[name] = {}
      if plugin.setup then
        Packer.plugin[name].setup_inner = ensure_fun(plugin.setup)
        Packer.plugin[name].setup_outer = function()
          if vim.fn['jetpack#tap'](name) then
            Packer.plugin[name].setup_inner()
          end
        end
        plugin.setup = ([[lua require('jetpack.packer').plugin[%q].setup_outer()]]):format(name)
      end
      if plugin.config then
        Packer.plugin[name].config_inner = ensure_fun(plugin.config)
        Packer.plugin[name].config_outer = function()
          if vim.fn['jetpack#tap'](name) then
            Packer.plugin[name].config_inner()
          end
        end
        plugin.config = ([[lua require('jetpack.packer').plugin[%q].config_outer()]]):format(name)
      end
      vim.fn['jetpack#add'](repo, plugin)
    end
  end
end

Packer.startup = function(config)
  vim.fn['jetpack#begin'](Packer.option.package_root)
  config(use)
  vim.fn['jetpack#end']()
end

package.preload['jetpack.packer'] = function()
  return Packer
end

local Paq = function(config)
  vim.fn['jetpack#begin']()
  for _, plugin in pairs(config) do
    use(plugin)
  end
  vim.fn['jetpack#end']()
end

package.preload['jetpack.paq'] = function()
  return Paq
end

local Jetpack = {}

for _, name in pairs({'begin', 'end', 'add', 'names', 'get', 'tap', 'sync', 'load'}) do
  Jetpack[name] = function(...) return vim.fn['jetpack#' .. name](...) end
end

Jetpack.startup = function(config)
  vim.cmd[[echomsg 'require("jetpack").startup() is deprecated. Please use require("jetpack.packer").startup() .']]
  Packer.startup(config)
end

Jetpack.setup = function(config)
  vim.cmd[[echomsg 'require("jetpack").setup() is deprecated. Please use require("jetpack.paq")() .']]
  Paq(config)
end

package.preload['jetpack'] = function()
  return Jetpack
end
========================================
