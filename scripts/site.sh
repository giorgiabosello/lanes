#!/bin/zsh
# Assembles the landing page into _site/: site/ plus the screenshots and logo
# from docs/images, so there is one copy of every image. The Pages workflow
# runs the same thing.
#   scripts/site.sh          build _site/
#   scripts/site.sh serve    build, then preview at http://localhost:8000
set -eu
cd "${0:A:h:h}"

rm -rf _site
mkdir -p _site/images
cp -R site/. _site/
cp docs/images/*.png docs/images/*.svg _site/images/

if [[ "${1:-}" == serve ]]; then
  print "Preview at http://localhost:8000 (Ctrl-C to stop)"
  cd _site && python3 -m http.server 8000
fi
