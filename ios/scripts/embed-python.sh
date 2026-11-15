#!/bin/bash
set -eo pipefail
cd "$PROJECT_DIR"
source Dependencies/Python.xcframework/build/utils.sh
# Sign nested extension frameworks ad hoc when producing the sideloadable unsigned IPA.
export EXPANDED_CODE_SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
export EXPANDED_CODE_SIGN_IDENTITY_NAME="${EXPANDED_CODE_SIGN_IDENTITY_NAME:-Ad Hoc}"
install_python Dependencies/Python.xcframework
mkdir -p "$CODESIGNING_FOLDER_PATH/app" "$CODESIGNING_FOLDER_PATH/app_packages"
rsync -a --delete PythonApp/ "$CODESIGNING_FOLDER_PATH/app/" --exclude __pycache__
rsync -a --delete Dependencies/python-packages/ "$CODESIGNING_FOLDER_PATH/app_packages/" --exclude __pycache__
