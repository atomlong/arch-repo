#!/bin/bash

# Check if a repo exist
check_repo_exist()
{
local repo_name=${1}
local repo_url=$(sed -r "s|(.*/)[^/]+(\s*$)|\1${repo_name##*/}.git\2|" <<< ${GH_URL})
local RES
while true; do
RES=$(curl -L -o /dev/null -s -w "%{http_code}" ${repo_url})
[ "$?" == 0 ] || continue
[ "${RES}" == 200 ] && { echo "${repo_url}"; return 0; }
[ "${RES}" == 404 ] && return 1
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

REPO_URL=$(check_repo_exist ${REPO_NAME}) || { echo "Not found repo ${REPO_NAME} on your account."; return 1; }

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

# Add/Remove a submodule as build marker file
submodule_auto()
{
local BM_FILES=(
https://efiles.cf/archlinux/x86_64/build.marker
https://efiles.cf/archlinuxarm/aarch64/build.marker
https://efiles.cf/archlinuxarm/armv7h/build.marker
)
local bm mod submodules

submodules=($(git config --file .gitmodules --name-only --get-regexp "submodule\..*\.path" | grep -Po '^submodule\.\K\S+(?=\.path)'))

for bm in ${BM_FILES[@]}; do
for mod in $(curl -sL ${bm} | grep -Po '^\[\w+\]((?!://).)*?\K[^/\s]+(?=\s*$)'); do
git config --file .gitmodules --name-only --get-regexp "submodule.${mod}.path" &>/dev/null || submodule_add ${mod}
done
done

for mod in ${submodules}; do
check_repo_exist ${mod} || submodule_remove ${mod}
done
}

# Run from here ......
THIS_DIR=$(readlink -f "$(dirname ${0})")
ROOT_DIR=$(readlink -f ${THIS_DIR}/../)
GH_URL=$(git config --get remote.origin.url)
COMMAND=${1}
shift
REPO_LIST=(${@})

pushd ${ROOT_DIR}
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
	auto)
		submodule_auto
		;;
	*)
		echo "Unknown command '${COMMAND}'"
		exit 1
		;;
esac
popd
