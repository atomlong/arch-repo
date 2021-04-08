#!/bin/bash

set -e

# AppVeyor and Drone Continuous Integration for ALARM
# Author: Atom Long <atom.long@hotmail.com>

# Enable colors
if [[ -t 1 ]]; then
    normal='\e[0m'
    red='\e[1;31m'
    green='\e[1;32m'
    cyan='\e[1;36m'
fi

# Basic status function
_status() {
    local type="${1}"
    local status="${package:+${package}: }${2}"
    local items=("${@:3}")
    case "${type}" in
        failure) local -n nameref_color='red';   title='[ALARM CI] FAILURE:' ;;
        success) local -n nameref_color='green'; title='[ALARM CI] SUCCESS:' ;;
        message) local -n nameref_color='cyan';  title='[ALARM CI]'
    esac
    printf "\n${nameref_color}${title}${normal} ${status}\n\n"
    printf "${items:+\t%s\n}" "${items:+${items[@]}}"
}

# Convert lines to array
_as_list() {
    local -n nameref_list="${1}"
    local filter="${2}"
    local strip="${3}"
    local lines="${4}"
    local result=1
    nameref_list=()
    while IFS= read -r line; do
        test -z "${line}" && continue
        result=0
        [[ "${line}" = ${filter} ]] && nameref_list+=("${line/${strip}/}")
    done <<< "${lines}"
    return "${result}"
}

# Lock the local file to prevent it from being modified by another instance.
_lock_file()
{
local lockfile=${LOCK_FILE_DIR}/${1}.lck
echo "$$" >> ${lockfile}
while [ "$(cat ${lockfile} | head -n 1)" != "$$" ]; do :; done
return 0
}

# Release the local file to allow it to be modified by another instance.
_release_file()
{
local lockfile=${LOCK_FILE_DIR}/${1}.lck
[ -f "${lockfile}" ] || return 0
while [ "$(head -n 1 ${lockfile})" == "$$" ]; do
sed -i '1d' ${lockfile}
done
[ ! -s ${lockfile} ] && rm -vf ${lockfile}
return 0
}

# Changes since last build
_list_changes() {
    local list_name="${1}"
    local filter="${2}"
    local strip="${3}"
    local git_options=("${@:4}")
	local marker="build.marker"
    local branch_url="$(git remote get-url origin | sed 's/\.git$//')/tree/${CI_BRANCH}"
	local commit_sha
	
	commit_sha=$(rclone cat "${DEPLOY_PATH}/${marker}" 2>/dev/null | sed -rn "s|^\[([[:xdigit:]]+)\]${branch_url}\s*$|\1|p")
	[ -n "${commit_sha}" ] || commit_sha="HEAD^"
	
	_as_list "${list_name}" "${filter}" "${strip}" "$(git log "${git_options[@]}" ${commit_sha}.. | sort -u)"
}

# log git sha for the current build
_create_build_marker() {
	local branch_url="$(git remote get-url origin | sed 's/\.git$//')/tree/${CI_BRANCH}"
	local marker="build.marker"
	
	_lock_file "${marker}"
	rclone lsf "${DEPLOY_PATH}/${marker}" &>/dev/null && while ! rclone copy "${DEPLOY_PATH}/${marker}" . &>/dev/null; do :; done || touch "${marker}"
	grep -Pq "\[[[:xdigit:]]+\]${branch_url}\s*$" ${marker} && \
	sed -i -r "s|^(\[)[[:xdigit:]]+(\]${branch_url}\s*)$|\1${CI_COMMIT}\2|g" "${marker}" || \
	echo "[${CI_COMMIT}]${branch_url}" >> "${marker}"
	rclone move "${marker}" "${DEPLOY_PATH}"
	_release_file "${marker}"
}

# Get package information
_package_info() {
    local package="${1}"
    local properties=("${@:2}")
    for property in "${properties[@]}"; do
        local -n nameref_property="${property}"
        nameref_property=($(
            source "${package}/PKGBUILD"
            declare -n nameref_property="${property}"
            echo "${nameref_property[@]}"))
    done
}

# Package provides another
_package_provides() {
    local package="${1}"
    local another="${2}"
    local pkgname provides
    _package_info "${package}" pkgname provides
    for pkg_name in "${pkgname[@]}";  do [[ "${pkg_name}" = "${another}" ]] && return 0; done
    for provided in "${provides[@]}"; do [[ "${provided}" = "${another}" ]] && return 0; done
    return 1
}

# Add package to build after required dependencies
_build_add() {
    local package="${1}"
    local depends makedepends
    for sorted_package in "${sorted_packages[@]}"; do
        [[ "${sorted_package}" = "${package}" ]] && return 0
    done
    _package_info "${package}" depends makedepends
    for dependency in "${depends[@]}" "${makedepends[@]}"; do
        for unsorted_package in "${packages[@]}"; do
            [[ "${package}" = "${unsorted_package}" ]] && continue
            _package_provides "${unsorted_package}" "${dependency}" && _build_add "${unsorted_package}"
        done
    done
    sorted_packages+=("${package}")
}

# get last commit hash of one package
_last_package_hash()
{
local package="${1}"
local marker="build.marker"
rclone cat "${DEPLOY_PATH}/${marker}" 2>/dev/null | sed -rn "s|^\[([[:xdigit:]]+)\]${package}\s*$|\1|p"
return 0
}

# get current commit hash of one package
_now_package_hash()
{
local package="${1}"
git log --pretty=format:'%H' -1 ${package} 2>/dev/null
return 0
}

# record current commit hash of one package
_record_package_hash()
{
local package="${1}"
local marker="build.marker"
local commit_sha

_lock_file "${marker}"
commit_sha="$(_now_package_hash ${package})"
rclone lsf "${DEPLOY_PATH}/${marker}" &>/dev/null && while ! rclone copy "${DEPLOY_PATH}/${marker}" . &>/dev/null; do :; done || touch "${marker}"
grep -Pq "\[[[:xdigit:]]+\]${package}\s*$" ${marker} && \
sed -i -r "s|^(\[)[[:xdigit:]]+(\]${package}\s*)$|\1${commit_sha}\2|g" "${marker}" || \
echo "[${commit_sha}]${package}" >> "${marker}"
rclone move "${marker}" "${DEPLOY_PATH}"
_release_file "${marker}"
return 0
}

# Git configuration
git_config() {
    local name="${1}"
    local value="${2}"
    test -n "$(git config ${name})" && return 0
    git config --global "${name}" "${value}" && return 0
    failure 'Could not configure Git for makepkg'
}

# Run command with status
execute(){
    local status="${1}"
    local command="${2}"
    local arguments=("${@:3}")
    message "${status}"
    if [[ "${command}" != *:* ]]
        then ${command} ${arguments[@]}
        else ${command%%:*} | ${command#*:} ${arguments[@]}
    fi || failure "${status} failed"
}

# Sort packages by dependency
define_build_order() {
    local sorted_packages=()
    for unsorted_package in "${packages[@]}"; do
        _build_add "${unsorted_package}"
    done
    packages=("${sorted_packages[@]}")
}

# Added commits
list_commits()  {
    _list_changes commits '*' '#*::' --pretty=format:'%ai::[%h] %s'
}

# Changed recipes
list_packages() {
    local _packages
    _list_changes _packages '*/PKGBUILD' '%/PKGBUILD' --pretty=format: --name-only || return 1
    for _package in "${_packages[@]}"; do
        local find_case_sensitive="$(find -name "${_package}" -type d -print -quit)"
        test -n "${find_case_sensitive}" && packages+=("${_package}")
    done
    return 0
}

# Add custom repositories to pacman
add_custom_repos()
{
[ -n "${CUSTOM_REPOS}" ] || { echo "You must set CUSTOM_REPOS firstly."; return 1; }
local repos=(${CUSTOM_REPOS//,/ })
local repo name
for repo in ${repos[@]}; do
name=$(sed -n -r 's/\[(\w+)\].*/\1/p' <<< ${repo})
[ -n "${name}" ] || continue
[ -z $(sed -rn "/^\\[${name}]\s*$/p" /etc/pacman.conf) ] || continue
cp -vf /etc/pacman.conf{,.orig}
sed -r 's/]/&\nServer = /' <<< ${repo} >> /etc/pacman.conf
sed -i -r 's/^(SigLevel\s*=\s*).*/\1Never/' /etc/pacman.conf
pacman --sync --refresh --needed --noconfirm --disable-download-timeout ${name}-keyring && name="" || name="SigLevel = Never\n"
mv -vf /etc/pacman.conf{.orig,}
sed -r "s/]/&\n${name}Server = /" <<< ${repo} >> /etc/pacman.conf
done
}

# Function: Sign one or more pkgballs.
create_package_signature()
{
[ -n "${PGP_KEY_PASSWD}" ] || { echo "You must set PGP_KEY_PASSWD firstly."; return 1; } 
local pkg
# signature for distrib packages.
(ls ${ARTIFACTS_PATH}/${package}/*${PKGEXT} &>/dev/null) && {
pushd ${ARTIFACTS_PATH}/${package}
for pkg in *${PKGEXT}; do
gpg --pinentry-mode loopback --passphrase "${PGP_KEY_PASSWD}" -o "${pkg}.sig" -b "${pkg}"
done
popd
}

return 0
}

# Import pgp private key
import_pgp_seckey()
{
[ -n "${PGP_KEY_PASSWD}" ] || { echo "You must set PGP_KEY_PASSWD firstly."; return 1; } 
[ -n "${PGP_KEY}" ] || { echo "You must set PGP_KEY firstly."; return 1; }
gpg --import --pinentry-mode loopback --passphrase "${PGP_KEY_PASSWD}" <<< "${PGP_KEY}"
}

# Read password from keyboard
# Usage: Read_Passwd <varname>
Read_Passwd()
{
[ $# == 1 ] || { echo "Usage: Read_Passwd <varname>"; return 1; }
local char
local varname=${1}
local password=''

while IFS= read -r -s -n1 char; do
  [[ -z $char ]] && { printf '\n'; break; } # ENTER pressed; output \n and break.
  if [[ $char == $'\x7f' ]]; then # backspace was pressed
      # Remove last char from output variable.
      [[ -n $password ]] && password=${password%?}
      # Erase '*' to the left.
      printf '\b \b'
  else
    # Add typed char to output variable.
    password+=$char
    # Print '*' in its stead.
    printf '*'
  fi
done
eval ${varname}=${password}
}

# Build package
build_package()
{
[ -n "${ARTIFACTS_PATH}" ] || { echo "You must set ARTIFACTS_PATH firstly."; return 1; }
local depends makedepends arch buildarch
unset PKGEXT

rm -rf ${ARTIFACTS_PATH}/${package}

_package_info "${package}" depends{,_${PACMAN_ARCH}} makedepends{,_${PACMAN_ARCH}} arch buildarch PKGEXT SRCEXT
[ -n "${PKGEXT}" ] || PKGEXT=$(grep -Po "^PKGEXT=('|\")?\K[^'\"]+" /etc/makepkg.conf)
export PKGEXT=${PKGEXT}

[ "${arch}" == "any" ] || {
[ -n "${buildarch}" ] && {
[ "$((buildarch & 1<<0))" == "$((1<<0))" ] && arch=(${arch[@]} 'i686' 'x86_64' 'arm' 'armv6h' 'armv7h' 'aarch64')
[ "$((buildarch & 1<<1))" == "$((1<<1))" ] && arch=(${arch[@]} 'arm')
[ "$((buildarch & 1<<2))" == "$((1<<2))" ] && arch=(${arch[@]} 'armv7h')
[ "$((buildarch & 1<<3))" == "$((1<<3))" ] && arch=(${arch[@]} 'aarch64')
[ "$((buildarch & 1<<4))" == "$((1<<4))" ] && arch=(${arch[@]} 'armv6h')
true
} || {
arch=(${arch[@]} "${PACMAN_ARCH}")
}
}
arch=($(tr ' ' '\n' <<< ${arch[@]} | sort -u))

[ "${arch}" == "any" ] || grep -Pq "\b${PACMAN_ARCH}\b" <<< ${arch[@]} || { echo "The package '${package}' will not build for architecture '${PACMAN_ARCH}'"; return 0; }

sed -i -r "s|^(arch=\()[^)]+(\))|\1${arch[*]}\2|" ${package}/PKGBUILD

[ -n "${depends}" ] && pacman -S --needed --noconfirm --disable-download-timeout ${depends[@]}
[ -n "$(eval echo \${depends_${PACMAN_ARCH}})" ] && eval pacman -S --needed --noconfirm --disable-download-timeout \${depends_${PACMAN_ARCH}[@]}
[ -n "${makedepends}" ] && pacman -S --needed --noconfirm --disable-download-timeout ${makedepends[@]}
[ -n "$(eval echo \${makedepends_${PACMAN_ARCH}})" ] && eval pacman -S --needed --noconfirm --disable-download-timeout \${makedepends_${PACMAN_ARCH}[@]}

expect << EOF
set timeout -1
spawn su - alarm
expect -re "\\\\\[alarm@\[^\[:space:]]+ \[^]]+]"
send "pushd ${PWD}/${package}\r"
expect -re "\\\\\[alarm@\[^\[:space:]]+ \[^]]+]"
send "makepkg --noconfirm --skippgpcheck --nocheck --syncdeps --rmdeps --cleanbuild\r"
expect -re "\\\\\[alarm@\[^\[:space:]]+ \[^]]+]"
send "popd\r"
expect -re "\\\\\[alarm@\[^\[:space:]]+ \[^]]+]"
send "exit\r"
EOF

(ls ${package}/*${PKGEXT} &>/dev/null) && {
mkdir -pv ${ARTIFACTS_PATH}/${package}
mv -vf ${package}/*${PKGEXT} ${ARTIFACTS_PATH}/${package}
true
} || {
export FAILED_PKGS=(${FAILED_PKGS[@]} ${package})
}

}

# deploy artifacts
deploy_artifacts()
{
[ -n "${DEPLOY_PATH}" ] || { echo "You must set DEPLOY_PATH firstly."; return 1; }
local old_pkgs pkg file

(ls ${ARTIFACTS_PATH}/${package}/*${PKGEXT} &>/dev/null) || { echo "Skiped, no file to deploy"; return 0; }

_lock_file "${PACMAN_REPO}.db"

pushd ${ARTIFACTS_PATH}/${package}
export PKG_FILES=(${PKG_FILES[@]} $(ls *${PKGEXT}))
for file in ${PACMAN_REPO}.{db,files}{,.tar.xz}{,.old}; do
rclone lsf ${DEPLOY_PATH}/${file} &>/dev/null || continue
while ! rclone copy ${DEPLOY_PATH}/${file} ${PWD}; do :; done
done
old_pkgs=($(repo-add "${PACMAN_REPO}.db.tar.xz" *${PKGEXT} | tee /dev/stderr | grep -Po "\bRemoving existing entry '\K[^']+(?=')" || true))
for pkg in ${old_pkgs[@]}; do
for file in ${pkg}-{${PACMAN_ARCH},any}.pkg.tar.{xz,zst}{,.sig}; do
rclone delete ${DEPLOY_PATH}/${file} 2>/dev/null || true
done
done

rclone move ${ARTIFACTS_PATH}/${package} ${DEPLOY_PATH} --copy-links --delete-empty-src-dirs

popd
_record_package_hash "${package}"
_release_file "${PACMAN_REPO}.db"
}

# create mail message
create_mail_message()
{
local message item

[ -n "${PKG_FILES}" ] && {
message="<p>Successfully created the following package archive.</p>"
for item in ${PKG_FILES[@]}; do
message=${message}"<p><font color=\"green\">${item}</font></p>"
done
}

[ -n "${FAILED_PKGS}" ] && {
message=${message}"<p>Failed to build following packages. </p>"
for item in ${FAILED_PKGS[@]}; do
message=${message}"<p><font color=\"red\">${item}</font></p>"
done
}

[ -n "${message}" ] && {
message=${message}"<p>Architecture: ${PACMAN_ARCH}</p>"
# message=${message}"<p>Build Number: ${CI_BUILD_NUMBER}</p>"

# echo ::set-output name=message::${message}

# Send mail
cat > mail.txt << EOF
From: "Build" <${MAIL_USERNAME}>
To: "Atom" <${MAIL_TO}>
Subject: Build Result
Content-Type: text/html; charset="utf-8"

${message}
Bye!
EOF

curl --url "smtps://${MAIL_HOST}:${MAIL_PORT}" \
	--ssl-reqd  \
	--mail-from "${MAIL_USERNAME}" \
	--mail-rcpt "${MAIL_TO}" \
	--upload-file mail.txt \
	--user "${MAIL_USERNAME}:${MAIL_PASSWD}" \
	--insecure
rm -f mail.txt
}

return 0
}

# Status functions
failure() { local status="${1}"; local items=("${@:2}"); _status failure "${status}." "${items[@]}"; return 1; }
success() { local status="${1}"; local items=("${@:2}"); _status success "${status}." "${items[@]}"; return 0; }
message() { local status="${1}"; local items=("${@:2}"); _status message "${status}"  "${items[@]}"; }

# Run from here ......
if [ $(whoami) != "root" ]; then
echo "Should run by root only ! (switch to root by command 'su - root')"
exit 1
fi

echo -e "\033]0;[$$] Starting...\007"

# Configure
THIS_DIR=$(readlink -f "$(dirname '${0}')")
LOCK_FILE_DIR=${THIS_DIR}
BUILD_RAR=${THIS_DIR}/build.rar
BUILD_CFG=${THIS_DIR}/build.config

[ -z "${RAR_FILE_SECRET}" ] && {
echo "Enter the password to extract file '${BUILD_RAR##*/}'"
Read_Passwd RAR_FILE_SECRET
}
_lock_file "build.config"
unrar x -p"${RAR_FILE_SECRET}" -o+ -id[q] ${BUILD_RAR} ${BUILD_CFG%/*} || { _release_file "build.config"; exit 1; }
unset RAR_FILE_SECRET
[ -f "${BUILD_CFG}" ] && source ${BUILD_CFG} && rm -vf ${BUILD_CFG}
_release_file "build.config"

[ -z "${PACMAN_REPO}" ] && export PACMAN_REPO=$([ "$(uname -o)" == "Msys" ] && tr 'A-Z' 'a-z' <<< ${MSYSTEM%%[0-9]*} || echo "eyun")
[[ ${PACMAN_REPO} =~ '$' ]] && eval export PACMAN_REPO=${PACMAN_ARCH}
[ -z "${PACMAN_ARCH}" ] && export PACMAN_ARCH=$(sed -nr 's|^CARCH=\"(\w+).*|\1|p' /etc/makepkg.conf)
[[ ${PACMAN_ARCH} =~ '$' ]] && eval export PACMAN_ARCH=${PACMAN_ARCH}
[ -z "${DEPLOY_PATH}" ] && { echo "Environment variable 'DEPLOY_PATH' is required."; exit 1; }
[[ ${DEPLOY_PATH} =~ '$' ]] && eval export DEPLOY_PATH=${DEPLOY_PATH}
[ -z "${RCLONE_CONF_URL}" ] && { echo "Environment variable 'RCLONE_CONF_URL' is required."; exit 1; }
[ -z "${PGP_KEY_PASSWD}" ] && { echo "Environment variable 'PGP_KEY_PASSWD' is required."; exit 1; }
[ -z "${PGP_KEY}" ] && { echo "Environment variable 'PGP_KEY' is required."; exit 1; }
[ -z "${MAIL_HOST}" ] && { echo "Environment variable 'MAIL_HOST' is required."; exit 1; }
[ -z "${MAIL_PORT}" ] && { echo "Environment variable 'MAIL_PORT' is required."; exit 1; }
[ -z "${MAIL_USERNAME}" ] && { echo "Environment variable 'MAIL_USERNAME' is required."; exit 1; }
[ -z "${MAIL_PASSWD}" ] && { echo "Environment variable 'MAIL_PASSWD' is required."; exit 1; }
[ -z "${MAIL_TO}" ] && { echo "Environment variable 'MAIL_TO' is required."; exit 1; }
[ -z "${CUSTOM_REPOS}" ] || add_custom_repos
import_pgp_seckey

ARTIFACTS_PATH=${PWD}/artifacts/${PACMAN_REPO}/${PACMAN_ARCH}/package

_lock_file "pacman_sync"
pacman --sync --refresh --sysupgrade --needed --noconfirm --disable-download-timeout base-devel rclone expect git || { _release_file "pacman_sync"; exit 1; }
_release_file "pacman_sync"

grep -Pq "^alarm:" /etc/group || groupadd "alarm"
grep -Pq "^alarm:" /etc/passwd || useradd -m "alarm" -s "/bin/bash" -g "alarm"
chown -R alarm:alarm ${CI_BUILD_DIR}

git_config user.email 'atom.long@hotmail.com'
git_config user.name  'atomlong'

RCLONE_CONFIG_PATH=$(rclone config file | tail -n1)
mkdir -pv ${RCLONE_CONFIG_PATH%/*}
[ -f "${RCLONE_CONFIG_PATH}" ] && mv -vf  ${RCLONE_CONFIG_PATH}{,.orig}
curl -L ${RCLONE_CONF_URL} -o ${RCLONE_CONFIG_PATH}.gpg
gpg --pinentry-mode loopback --passphrase "${PGP_KEY_PASSWD}" --output ${RCLONE_CONFIG_PATH} --decrypt ${RCLONE_CONFIG_PATH}.gpg
rm -vf ${RCLONE_CONFIG_PATH}{.gpg,.orig}

pushd ${CI_BUILD_DIR}
[ $# == 0 ] && {
# Detect
list_commits  || { failure 'Could not detect added commits'; exit 1; }
list_packages || { failure 'Could not detect changed files'; exit 1; }
message 'Processing changes' "${commits[@]}"
[ -z "${packages}" ] && { success 'No changes in package recipes'; exit 0; }
true
} || {
packages=(${@})
}
define_build_order || failure 'Could not determine build order'

# Build
message 'Building packages' "${packages[@]}"
IPKG=0
for package in "${packages[@]}"; do
echo -e "\033]0;[$$] $((++IPKG))/${#packages[@]} - ${package}\007"
[ "$(_last_package_hash ${package})" == "$(_now_package_hash ${package})" ] && continue
git submodule update --progress --init "${package}"
execute 'Building packages' build_package
[ -d "${ARTIFACTS_PATH}/${package}" ] || continue
execute "Generating package signature" create_package_signature
execute "Deploying artifacts" deploy_artifacts
_lock_file "pacman_sync"
pacman --sync --refresh --noconfirm --disable-download-timeout
_release_file "pacman_sync"
done
_create_build_marker
create_mail_message
[ -z "${FAILED_PKGS}" ] && success 'All packages built successfully'
popd
