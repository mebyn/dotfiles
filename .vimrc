" Set OS specific settings
if has('macunix')
   set clipboard=unnamed
   set belloff=all
elseif has('unix')
   set clipboard=unnamedplus
endif
set number
map <Space> <Leader>

" Install vim-plug if not found
if empty(glob('~/.vim/autoload/plug.vim'))
  silent !curl -fLo ~/.vim/autoload/plug.vim --create-dirs
    \ https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
  autocmd VimEnter * PlugInstall --sync | source $MYVIMRC
endif

call plug#begin('~/.vim/plugged')

Plug 'catppuccin/vim', { 'as': 'catppuccin' }

Plug 'junegunn/vim-easy-align'

Plug 'https://github.com/tpope/vim-surround.git'

Plug 'preservim/nerdtree'

Plug 'preservim/nerdcommenter'

call plug#end()

set visualbell
set noerrorbells
set termguicolors
set background=dark
set rnu
colorscheme catppuccin_mocha
autocmd FileType yaml setlocal ts=2 sts=2 sw=2 expandtab

" Show Whitespace toggle
hi Whitespace ctermfg=DarkGray
match Whitespace /\s/
set listchars=tab:⇤–⇥,space:·,trail:·,precedes:⇠,extends:⇢,nbsp:×
set list!
noremap <F5> :set list!<CR>
inoremap <F5> <C-o>:set list!<CR>
cnoremap <F5> <C-c>:set list!<CR>
