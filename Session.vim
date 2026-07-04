let SessionLoad = 1
let s:so_save = &g:so | let s:siso_save = &g:siso | setg so=0 siso=0 | setl so=-1 siso=-1
let v:this_session=expand("<sfile>:p")
silent only
silent tabonly
cd ~/projects/opencode-patched
if expand('%') == '' && !&modified && line('$') <= 1 && getline(1) == ''
  let s:wipebuf = bufnr('%')
endif
let s:shortmess_save = &shortmess
if &shortmess =~ 'A'
  set shortmess=aoOA
else
  set shortmess=aoO
endif
badd +0 term://~/projects/opencode-patched//1949323:/nix/store/4caysh29k5ann696v7k32xk36w8xa61s-bash-interactive-5.3p3/bin/bash
argglobal
%argdel
argglobal
if bufexists(fnamemodify("term://~/projects/opencode-patched//1949323:/nix/store/4caysh29k5ann696v7k32xk36w8xa61s-bash-interactive-5.3p3/bin/bash", ":p")) | buffer term://~/projects/opencode-patched//1949323:/nix/store/4caysh29k5ann696v7k32xk36w8xa61s-bash-interactive-5.3p3/bin/bash | else | edit term://~/projects/opencode-patched//1949323:/nix/store/4caysh29k5ann696v7k32xk36w8xa61s-bash-interactive-5.3p3/bin/bash | endif
if &buftype ==# 'terminal'
  silent file term://~/projects/opencode-patched//1949323:/nix/store/4caysh29k5ann696v7k32xk36w8xa61s-bash-interactive-5.3p3/bin/bash
endif
balt term://~/projects/opencode-patched//1949323:/nix/store/4caysh29k5ann696v7k32xk36w8xa61s-bash-interactive-5.3p3/bin/bash
setlocal foldmethod=expr
setlocal foldexpr=nvim_treesitter#foldexpr()
setlocal foldmarker={{{,}}}
setlocal foldignore=#
setlocal foldlevel=0
setlocal foldminlines=1
setlocal foldnestmax=20
setlocal nofoldenable
let s:l = 73 - ((72 * winheight(0) + 38) / 76)
if s:l < 1 | let s:l = 1 | endif
keepjumps exe s:l
normal! zt
keepjumps 73
normal! 043|
tabnext 1
if exists('s:wipebuf') && len(win_findbuf(s:wipebuf)) == 0 && getbufvar(s:wipebuf, '&buftype') isnot# 'terminal'
  silent exe 'bwipe ' . s:wipebuf
endif
unlet! s:wipebuf
set winheight=1 winwidth=20
let &shortmess = s:shortmess_save
let s:sx = expand("<sfile>:p:r")."x.vim"
if filereadable(s:sx)
  exe "source " . fnameescape(s:sx)
endif
let &g:so = s:so_save | let &g:siso = s:siso_save
set hlsearch
nohlsearch
let g:this_session = v:this_session
let g:this_obsession = v:this_session
doautoall SessionLoadPost
unlet SessionLoad
" vim: set ft=vim :
