FROM docker.io/library/python:3.13-bookworm

# Python setup. Makes a venv and sets it as the default Python interpreter
ENV VIRTUAL_ENV=/root/.venv
RUN python -m venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

# Install radian, a Julia-inspired R REPL written in Python
RUN pip install -U radian

ENV R_VERSION="4.5.0"
ENV QUARTO_VERSION="1.7.29"

RUN <<EOF
# Install R
# Taken from https://github.com/r-lib/rig?tab=readme-ov-file#installing-rig-on-linux-

# Get their certificate
curl -L https://rig.r-pkg.org/deb/rig.gpg -o /etc/apt/trusted.gpg.d/rig.gpg
sh -c 'echo "deb http://rig.r-pkg.org/deb rig main" > /etc/apt/sources.list.d/rig.list'
apt-get update

# Now rig is available to install
apt-get install r-rig

# Install this version of R
rig add ${R_VERSION}

echo "options(repos = c(CRAN = 'https://packagemanager.posit.co/cran/__linux__/bookworm/latest'))\n" >> ~/.Rprofile
Rscript -e "options(warn = 2); pak::pak(c('knitr', 'rmarkdown', 'languageserver', 'nx10/httpgd'))"
EOF

RUN <<EOF
# Set up the R graphics driver
echo "if (interactive()) {
  if ('httpgd' %in% .packages(all.available = TRUE)) {
    options(device = function(...) {
      httpgd::hgd(host = '0.0.0.0', port = 9001, token = FALSE)
    })
  }
}\n" >> ~/.Rprofile
EOF

RUN <<EOF
# Set up and start the R help HTML pages when R loads.
# 127.0.0.1:20000 gets bound to 0.0.0.0:20633, because you can't access
# 127.0.0.1 from outside the container, but you can access 0.0.0.0.
# When running the container add `-p 20633:20633`
echo "if (interactive()) {
  options('help.ports' = 20000)
  system('socat TCP-LISTEN:20633,bind=0.0.0.0,fork TCP:127.0.0.1:20000 &')

  cli::cli_h1('HTML help pages')
  cli::cli_alert_info('Starting httpd help server...')

  resp <- suppressMessages(tools::startDynamicHelp())

  if (resp != 20000) {
    cli::cli_alert_danger('Failed to start server. Try running {.fn tools::startDynamicHelp} manually to see what happens.')
    cli::cli_text('')
  } else {
    cli::cli_alert_info('If container is running with {.code -p 20633:20633}')
    cli::cli_alert_info('{.url http://localhost:20633/doc/html/index.html}')
    cli::cli_text('')
  }

  rm(resp)

  .Last <- function() {
    # Attempt to clean up after ourselves when R closes.
    # When R closes the help pages are no longer served, so we
    # should also stop socat.

    # A bit of a blunt instrument as it will terminal ALL instances
    # of socat. But I'm assuming for this container that R help will
    # be the sole user of the command, so it's safe to do
    x <- suppressWarnings(system('pgrep socat', intern = TRUE))
    if (length(x) >= 1L) {
      system('pgrep socat | xargs kill -9')
    }
  }
}\n" >> ~/.Rprofile

# Install system dependency
apt-get install -y --no-install-recommends socat
EOF

RUN <<EOF
# Install Quarto.
# Slightly modified from 
# https://docs.posit.co/resources/install-quarto.html

mkdir -p /opt/quarto/${QUARTO_VERSION}

curl -o quarto.tar.gz -L \
    "https://github.com/quarto-dev/quarto-cli/releases/download/v${QUARTO_VERSION}/quarto-${QUARTO_VERSION}-linux-amd64.tar.gz"

tar -zxvf quarto.tar.gz \
    -C "/opt/quarto/${QUARTO_VERSION}" \
    --strip-components=1

rm quarto.tar.gz

# Symlink so that `quarto` can be used as a command
ln -s /opt/quarto/${QUARTO_VERSION}/bin/quarto /usr/local/bin/quarto

# Verify successful installation
quarto check
EOF

# deno is required for one of the plugins
COPY --from=denoland/deno:bin /deno /usr/local/bin/deno

RUN <<EOF
# Neovim plugin system deps
apt-get install -y --no-install-recommends ripgrep fd-find

# Instructions for fd from: https://github.com/sharkdp/fd?tab=readme-ov-file#on-debian
mkdir -p ~/.local/bin/fd
ln -s $(which fdfind) ~/.local/bin/fd
echo 'export PATH="$PATH:/$HOME/.local/bin"' >> ~/.bashrc
EOF

RUN <<EOF
# Get Neovim config

mkdir -p ~/.config/nvim
curl -o config.tar.gz -L "https://codeberg.org/pjphd/neovim_config/archive/main.tar.gz"
tar -zxvf config.tar.gz -C ~/.config/nvim --strip-components=1

rm config.tar.gz
EOF

RUN <<EOF
# Install Neovim
# Taken from https://github.com/neovim/neovim/blob/master/INSTALL.md#pre-built-archives-2

curl -LO https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz
rm -rf /opt/nvim
tar -C /opt -xzf nvim-linux-x86_64.tar.gz
echo 'export PATH="$PATH:/opt/nvim-linux-x86_64/bin"' >> ~/.bashrc

rm nvim-linux-x86_64.tar.gz
EOF

# Tidy up apt
RUN apt clean && rm -rf /var/lib/apt/lists/*

CMD /bin/bash
