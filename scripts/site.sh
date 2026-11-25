#!/bin/sh
# Assembles the website into _site/: site/ plus the screenshots and logo from
# docs/images, so there is one copy of every image, and the changelog page
# filled in from CHANGELOG.md. The Pages workflow runs this same script.
#   scripts/site.sh          build _site/
#   scripts/site.sh serve    build, then preview at http://localhost:8000
set -eu
cd "$(dirname "$0")/.."

rm -rf _site
mkdir -p _site/images
cp -R site/. _site/
cp docs/images/*.png docs/images/*.svg _site/images/
python3 scripts/changelog.py html site/changelog.html _site/changelog.html

if [ "${1:-}" = serve ]; then
  echo "Preview at http://localhost:8000 (Ctrl-C to stop)"
  cd _site && python3 -m http.server 8000
fi
