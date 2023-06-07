#!/bin/bash

# Check if a repo exist
check_repo_exist()
{
local repo_name="${1}"
local repo_url="${GH_HOME}/${repo_name##*/}.git"
local RES
while true; do
RES=$(GIT_TERMINAL_PROMPT=0 git ls-remote ${repo_url} 2>&1)
[ $? == 0 ] && { echo "${repo_url}"; return 0; }
grep -q "^fatal: unable to access" <<< "${RES}" && continue
grep -q "^error: RPC failed" <<< "${RES}" && continue
return 1
done
}

# Add a submodule
submodule_add()
{
[ "$#" == 1 ] || { echo "Usage: submodule_add submod"; return 1; }
local REPO_NAME=${1}
local REPO_URL

git config --file .gitmodules --name-only --get-regexp "submodule.${REPO_NAME}.path" &>/dev/null && {
echo "Submodule ${REPO_NAME} exists."
return 0
}

REPO_URL=$(check_repo_exist ${REPO_NAME}) || { echo "Not found repo ${REPO_NAME} on your account."; set +x; return 1; }

while ! git submodule add "${REPO_URL}" "${REPO_NAME}" 2>/dev/null; do
rm -rf "${REPO_NAME}"
done

submodules=($(sed -n -r 's/^\[submodule\s+"(.*)"\s*\]\s*$/\1/p' .gitmodules | sort -u))
mod_insert=$(sed -r "s/(^|.*\s)${REPO_NAME}( (\S+).*|$)/\3/" <<< "${submodules[@]}")
[ -z "${mod_insert}" ] || {
subm_info=$(sed -nr "/^\[submodule \"${REPO_NAME}\"\]/,/^\[.*\]/p" .gitmodules | sed -r '${ /^\[.*\]/d }')
subm_info_s=$(sed -nr "/^\[submodule \"${REPO_NAME}\"\]/=" .gitmodules)
subm_info_n=$(wc -l <<< "${subm_info}")
subm_info="${subm_info//[/\\[}"
subm_info="${subm_info//]/\\]}"
subm_info="${subm_info//\"/\\\"}"
subm_info=$(sed ':label;N;s/\n/\\n/;b label' <<< "${subm_info}")
sed -i "${subm_info_s},$((subm_info_s+subm_info_n-1))d" .gitmodules
sed -i "/\[submodule \"${mod_insert}\"\]/i ${subm_info}" .gitmodules
}
git add .gitmodules ${REPO_NAME}/
git commit -m "add submodule \"${REPO_NAME}\""

return 0
}

# Remove a submodule
submodule_remove()
{
[ "$#" == 1 ] || { echo "Usage: submodule_remove submod"; return 1; }
local REPO_NAME=${1}
local REPO_PATH

REPO_PATH=$(git config --file .gitmodules --get-regexp submodule.${REPO_NAME}.path | awk '{print $2}')
[ -n "${REPO_PATH}" ] || {
echo "Submodule ${REPO_NAME} not exists."
return 0
}

git rm -f ${REPO_PATH}
rm -rf .git/modules/${REPO_PATH}
git commit -m "remove submodule \"${REPO_NAME}\""
}

# update submodules
submodule_sync()
{
[ "$#" == 1 ] || { echo "Usage: submodule_sync submod"; return 1; }
local REPO_NAME=${1}
git submodule update --remote "${REPO_NAME}"
git diff --exit-code "${REPO_NAME}" >/dev/null || {
git commit -m "update submodule \"${REPO_NAME}\"" "${REPO_NAME}"
}
}

# Init submodules
submodule_init()
{
[ -z "${GH_TOKEN}" ] && { echo "GH_TOKEN not set"; return 1; }
[ -z "${GH_HOME}" ] && { echo "GH_HOME not set"; return 1; }
local err
git config --global url."${GH_HOME/\/\////${GH_TOKEN}@}".insteadOf "${GH_HOME}"
err=$(git submodule update --init --recursive 2>&1 | tee /dev/stderr | sed -n "/fatal: repository .* not found/p"
exit ${PIPESTATUS})
[ $? == 0 ] || [ -n "${err}" ]
}

# Create or Update secrets for a submodule
submodule_secrets()
{
[ "$#" == 1 ] || { echo "Usage: submodule_secrets submod"; return 1; }
local REPO_NAME=${1}
[ -d "${REPO_NAME}" ] || { echo "No ${REPO_NAME} sub folder"; return 1; }
pushd "${REPO_NAME}"
[ -n "${RCLONE_CONF}" ]    && while ! (sleep 1 && gh secret set RCLONE_CONF		-b"${RCLONE_CONF}" 2>/dev/null); do :; done
[ -n "${PGP_KEY}" ]        && while ! (sleep 1 && gh secret set PGP_KEY			-b"${PGP_KEY}" 2>/dev/null); do :; done
[ -n "${PGP_KEY_PASSWD}" ] && while ! (sleep 1 && gh secret set PGP_KEY_PASSWD	-b"${PGP_KEY_PASSWD}" 2>/dev/null); do :; done
[ -n "${PACMAN_REPO}" ]    && while ! (sleep 1 && gh secret set PACMAN_REPO		-b"${PACMAN_REPO}" 2>/dev/null); do :; done
[ -n "${DEPLOY_PATH}" ]    && while ! (sleep 1 && gh secret set DEPLOY_PATH		-b"${DEPLOY_PATH}" 2>/dev/null); do :; done
[ -n "${CUSTOM_REPOS}" ]   && while ! (sleep 1 && gh secret set CUSTOM_REPOS	-b"${CUSTOM_REPOS}" 2>/dev/null); do :; done
[ -n "${MAIL_HOST}" ]      && while ! (sleep 1 && gh secret set MAIL_HOST		-b"${MAIL_HOST}" 2>/dev/null); do :; done
[ -n "${MAIL_PORT}" ]      && while ! (sleep 1 && gh secret set MAIL_PORT		-b"${MAIL_PORT}" 2>/dev/null); do :; done
[ -n "${MAIL_USERNAME}" ]  && while ! (sleep 1 && gh secret set MAIL_USERNAME	-b"${MAIL_USERNAME}" 2>/dev/null); do :; done
[ -n "${MAIL_PASSWORD}" ]  && while ! (sleep 1 && gh secret set MAIL_PASSWORD	-b"${MAIL_PASSWORD}" 2>/dev/null); do :; done
[ -n "${MAIL_TO}" ]        && while ! (sleep 1 && gh secret set MAIL_TO			-b"${MAIL_TO}" 2>/dev/null); do :; done
[ -n "${MARKER_PATH}" ]    && while ! (sleep 1 && gh secret set MARKER_PATH		-b"${MARKER_PATH}" 2>/dev/null); do :; done
popd
}

# Add/Remove a submodule as build marker file
# Please set the http location of build marker files via GH_TOKEN before call this function
# example:
# BM_FILES="https://example.com/archlinux/x86_64/build.marker
# https://example.com/archlinuxarm/aarch64/build.marker
# https://example.com/archlinuxarm/armv7h/build.marker"
submodule_auto()
{
[ -z "${BM_FILES}" ] && { echo "BM_FILES not set"; return 1; }
local bm mod submodules h m

submodules=($(git config --file .gitmodules --name-only --get-regexp "submodule\..*\.path" | grep -Po '^submodule\.\K\S+(?=\.path)'))

h=$(git rev-parse HEAD)
for mod in ${submodules[@]}; do
submodule_sync ${mod}
done
m="$(git log ${h}..HEAD --format=%s)"
[ -z "${m}" ] || {
git reset --soft "${h}"
git commit -m "Submodule Update
${m}"
}

for bm in ${BM_FILES}; do
for mod in $(curl -sL ${bm} | grep -Po '^\[\w+\]((?!://).)*?\K[^/\s]+(?=\s*$)'); do
git config --file .gitmodules --name-only --get-regexp "submodule.${mod}.path" &>/dev/null || submodule_add ${mod}
done
done

for mod in ${submodules[@]}; do
check_repo_exist ${mod} >/dev/null || submodule_remove ${mod}
done

for mod in ${submodules[@]}; do
submodule_secrets ${mod}
done
}

# Run from here ......
THIS_DIR=$(readlink -f "$(dirname ${0})")
ROOT_DIR=$(readlink -f ${THIS_DIR}/../)
GH_URL=$(git config --get remote.origin.url)
GH_HOME="${GH_URL%/*}"
COMMAND=${1}
shift
REPO_LIST=(${@})

pushd ${ROOT_DIR}
submodule_init || exit 1
case ${COMMAND} in
	add)
		for repo in ${REPO_LIST[@]}; do
		submodule_add ${repo}
		done
		;;
	remove)
		for repo in ${REPO_LIST[@]}; do
		submodule_remove ${repo}
		done
		;;
	sync)
		for repo in ${REPO_LIST[@]}; do
		submodule_sync ${repo}
		done
		;;
	secrets)
		for repo in ${REPO_LIST[@]}; do
		submodule_secrets ${repo}
		done
		;;
	auto)
		submodule_auto
		;;
	*)
		echo "Unknown command '${COMMAND}'"
		exit 1
		;;
esac
popd
