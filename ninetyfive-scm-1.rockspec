local MODREV, SPECREV = 'scm', '-1'
rockspec_format = '3.0'
package = 'ninetyfive'
version = MODREV .. SPECREV

description = {
  summary = 'A very fast suggestion provider',
  labels = { 'neovim' },
  detailed = [[
  	TODO
   ]],
  homepage = 'https://github.com/numerataz/ninetyfive.nvim',
  license = 'MIT',
}

dependencies = {
  'lua >= 5.1, < 5.4',
}

source = {
  url = 'git://github.com/numerataz/ninetyfive.nvim',
}

build = {
  type = 'builtin',
  copy_directories = {
    'autoload',
    'plugin',
    'doc'
  }
}
