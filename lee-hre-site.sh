#!/bin/sh

set -e
error_msg() { printf "\033[31m%s\033[0m\n" "$*"; }
notice_msg() { printf "\033[33m%s\033[0m " "$*"; }
done_msg() { printf "\033[32m%s\033[0m\n" "$*"; }
DONE_MSG=$(done_msg done)


ARGUMENTS_FILE="$(tempfile)"
truncate --size=0 "$ARGUMENTS_FILE"
FIRST=true
for ARG in "$@"
do
    if [ $FIRST = true ]
    then
	FIRST=false
    else
	printf '\0' >> "$ARGUMENTS_FILE"
    fi
    echo -n "$ARG" >> "$ARGUMENTS_FILE"
done

DEVELOPMENT_INSTALL=false
if [ x"$1" = x"--dev" -o x"$1" = x"--development" ]
then
    error_msg DEVELOPMENT INSTALL
    DEVELOPMENT_INSTALL=true
    shift
fi

DEFAULT_SERVER=false
DEFAULT_PARAMETER=
if [ x"$1" = x"--default" ]
then
    DEFAULT_SERVER=true
    DEFAULT_PARAMETER='--default'
    shift
fi

usage_and_exit() {
    cat >&2 <<EOUSAGE
Usage: $0 [--default] <SITE-NAME> <UNIX-USER> [HOST]
HOST is only optional if you are running this on an EC2 instance.
--default means to install as the default site for this server,
rather than a virtualhost for HOST.
EOUSAGE
    exit 1
}

if [ $# -lt 2 ]
then
    usage_and_exit
fi

SITE="$1"
UNIX_USER="$2"

case "$SITE" in
    fixmystreet | hwcc2025)
        echo ==== Installing $SITE;;
    *)
        echo Installing $SITE with this script is not currently supported.
        exit 1;;
esac











# Install some packages that we will definitely need:
echo -n "Updating package lists... "
apt-get -qq update #what is this 
echo $DONE_MSG
echo "Critical packages installation..."
for package in git lockfile-progs curl dnsutils lsb-release; do
    echo -n "  $package... "; apt-get -qq install -y $package >/dev/null; echo $DONE_MSG
done

if [ $DEVELOPMENT_INSTALL = true ]; then
    DIRECTORY=$(cd "."; pwd)
elif [ $DEFAULT_SERVER = true ]; then
    DIRECTORY="/var/www/$SITE"
else
    DIRECTORY="/var/www/$HOST"
fi

mkdir -p "$DIRECTORY"

COPIED_SCRIPT="$DIRECTORY/lee-hre-site.sh"

if [ ! -f "$0" ]
then
    error_msg "Couldn't find the location of this script:"
    error_msg "Please run it as './lee-hre-site.sh ...' or 'sh lee-hre-site.sh ...'"
    exit 1
fi

if [ "$(readlink -f "$0")" != "$(readlink -f "$COPIED_SCRIPT")" ]
then
    cp "$0" "$COPIED_SCRIPT"
fi
chmod a+rx "$COPIED_SCRIPT"

COPIED_ARGUMENTS="$DIRECTORY/install-arguments"
mv "$ARGUMENTS_FILE" "$COPIED_ARGUMENTS"
chmod a+r "$COPIED_ARGUMENTS"

# Save the host that's used for this installation:
OLD_HOST_FILE="$DIRECTORY/last-host"
echo "$HOST" > "$OLD_HOST_FILE"

REPOSITORY="$DIRECTORY/$SITE"

REPOSITORY_URL=git://github.com/lmanyonho/$SITE.git
BRANCH=master

DISTRIBUTION="$(lsb_release -i -s  | tr A-Z a-z)"
DISTVERSION="$(lsb_release -c -s)"

echo -n "Testing $HOST's IP address... "
IP_ADDRESS_FOR_HOST="$(dig +short $HOST)"

if [ x = x"$IP_ADDRESS_FOR_HOST" ]
then
    error_msg "The hostname $HOST didn't resolve to an IP address"
    exit 1
fi
echo $DONE_MSG

add_locale() {
    echo -n "Generating locale $1... "
    if [ "$(locale -a | egrep -i "^$1.utf-?8$" | wc -l)" = "1" ]
    then
        notice_msg already
    else
        if [ x"$DISTRIBUTION" = x"ubuntu" ]; then
            locale-gen "$1.UTF-8"
            locale-gen
        fi
    fi
    echo $DONE_MSG
}

generate_locales() {
    echo "Generating locales... "
    # If language-pack-en is present, install that:
    apt-get -qq install -y language-pack-en >/dev/null || true
    add_locale en_GB
    echo $DONE_MSG
}

set_locale() {
    echo 'LANG="en_GB.UTF-8"' > /etc/default/locale
    echo 'LC_ALL="en_GB.UTF-8"' >> /etc/default/locale
    export LANG="en_GB.UTF-8"
    export LC_ALL="en_GB.UTF-8"
}

add_unix_user() {
    echo -n "Adding unix user... "
    # Create the required user if it doesn't already exist:
    if id "$UNIX_USER" 2> /dev/null > /dev/null
    then
        notice_msg already
    else
        adduser --quiet --disabled-password --gecos "A user for the site $SITE" "$UNIX_USER"
    fi
    echo $DONE_MSG
}

add_postgresql_user() {
    SUPERUSER=${1:---no-createrole --no-superuser}
    su -l -c "createuser --createdb $SUPERUSER '$UNIX_USER'" postgres || true
}

update_apt_sources() {
    echo -n "Updating APT sources... "
    if [ x"$DISTRIBUTION" = x"ubuntu" ] && [ x"$DISTVERSION" = x"trusty" ]
    then
        : # Do nothing, let's see if we need multiverse
    else
        error_msg "Unsupported distribution and version combination $DISTRIBUTION $DISTVERSION"
        exit 1
    fi
    apt-get -qq update
    echo $DONE_MSG
}

clone_or_update_repository() {
    echo -n "Cloning or updating repository... "
    # Clone the repository into place if the directory isn't already
    # present:
    if [ -d "$REPOSITORY/.git" ]
    then
        if [ $DEVELOPMENT_INSTALL = true ]; then
            notice_msg skipping as development install...
        else
            notice_msg updating...
            cd $REPOSITORY
            git remote set-url origin "$REPOSITORY_URL"
            git fetch origin
            # Check that there are no uncommitted changes before doing a
            # git reset --hard:
            git diff --quiet || { echo "There were changes in the working tree in $REPOSITORY; exiting."; exit 1; }
            git diff --cached --quiet || { echo "There were staged but uncommitted changes in $REPOSITORY; exiting."; exit 1; }
            # If that was fine, carry on:
            git reset --quiet --hard origin/"$BRANCH"
            git submodule --quiet sync
            git submodule --quiet update --recursive
        fi
    else
        PARENT="$(dirname $REPOSITORY)"
        notice_msg cloning...
        mkdir -p $PARENT
        git clone --recursive --branch "$BRANCH" "$REPOSITORY_URL" "$REPOSITORY"
    fi
    echo $DONE_MSG
}

ensure_line_present() {
    MATCH_RE="$1"
    REQUIRED_LINE="$2"
    FILE="$3"
    MODE="$4"
    if [ -f "$FILE" ]
    then
        if egrep "$MATCH_RE" "$FILE" > /dev/null
        then
            sed -r -i -e "s#$MATCH_RE.*#$REQUIRED_LINE#" "$FILE"
        else
            TMP_FILE=$(mktemp)
            echo "$REQUIRED_LINE" > $TMP_FILE
            cat "$FILE" >> $TMP_FILE
            mv $TMP_FILE "$FILE"
        fi
    else
        echo "$REQUIRED_LINE" >> "$FILE"
    fi
    chmod "$MODE" "$FILE"
}

install_postfix() {
    echo -n "Installing postfix... "
    # Make sure debconf-set-selections is available
    apt-get -qq install -y debconf >/dev/null
    # Set the things so that we can do this non-interactively
    echo postfix postfix/main_mailer_type select 'Internet Site' | debconf-set-selections
    echo postfix postfix/mail_name string "$HOST" | debconf-set-selections
    # /etc/postfix/main.cf in site-specific-install.sh
    echo postfix postfix/destinations string \
        "$HOST, $(hostname --fqdn), localhost.localdomain, localhost" | debconf-set-selections
    DEBIAN_FRONTEND=noninteractive apt-get -qq -y install postfix >/dev/null
    echo $DONE_MSG
}

install_nginx() {
    echo -n "Installing nginx... "
    apt-get install -qq -y nginx libfcgi-procmanager-perl >/dev/null
    echo $DONE_MSG
}

install_postgis() {
    if [ x"$DISTRIBUTION" = x"ubuntu" ] && [ x"$DISTVERSION" = x"trusty" ]
    then
        # On trusty, we have Postgresql >= 9.1 (9.3) *and* PostGIS >= 2.0
        # and so PostGIS support should be installed with "CREATE EXTENSION
        # postgis; CREATE EXTENSION postgis_topology;" instead. (So this
        # condition would arguably be better written as a condition on
        # those two versions.)
        echo "PostGIS support should already be available."
    else
        echo -n "Installing PostGIS... "
        POSTGIS_SCRIPT='hre_db/db-script.sh'
        su -l -c "curl '$POSTGIS_SCRIPT' | bash -s" postgres
        # According to Matthew's installation instructions, these two SRID
        # may be missing the appropriate +datum from the proj4text column,
        # depending on what PostGIS version is being used.  Check whether
        # they are missing, and if so, update the column.
        for T in 27700:+datum=OSGB36 29902:+datum=ire65
        do
            SRID="${T%%:*}"
            DATUM="${T##*:}"
            EXISTING="$(echo "select proj4text from spatial_ref_sys where srid = '$SRID'" | su -l -c "psql -t -P 'format=unaligned' template_postgis" postgres)"
            if ! echo "$EXISTING" | grep -- "$DATUM"
            then
                echo Adding $DATUM to the proj4text column of spatial_ref_sys for srid $SRID
                NEW_VALUE="${EXISTING% } $DATUM "
                echo "UPDATE spatial_ref_sys SET proj4text = '$NEW_VALUE' WHERE srid = '$SRID'" | su -l -c 'psql template_postgis' postgres
            fi
        done
        echo $DONE_MSG
    fi
}

make_log_directory() {
    LOG_DIRECTORY="$DIRECTORY/hwcc2022/hwcc2022logs/"
    mkdir -p "$LOG_DIRECTORY/hwcc2022/"
    chown -R "$UNIX_USER"."$UNIX_USER" "$LOG_DIRECTORY/hwcc2022/"
}

add_website_to_nginx() {
    echo -n "Adding site to nginx... "
    NGINX_VERSION="$(/usr/sbin/nginx -v 2>&1 | sed 's,^nginx version: nginx/\([^ ]*\).*,\1,')"
    # The 'default_server' option is just 'default' in earlier
    # versions of nginx:
    if dpkg --compare-versions "$NGINX_VERSION" lt 0.8.21
    then
        DEFAULT_SERVER_OPTION=default
    else
        DEFAULT_SERVER_OPTION=default_server
    fi
    NGINX_SITE="$HOST"
    if [ $DEFAULT_SERVER = true ]
    then
        NGINX_SITE=default
    fi
    NGINX_SITE_FILENAME=/etc/nginx/sites-available/"$NGINX_SITE"
    NGINX_SITE_LINK=/etc/nginx/sites-enabled/"$NGINX_SITE"
    cp $CONF_DIRECTORY/nginx.conf.example $NGINX_SITE_FILENAME
    sed -i "s,/var/www/$SITE,$DIRECTORY," $NGINX_SITE_FILENAME
    if [ $DEFAULT_SERVER = true ]
    then
        sed -i "s/^.*listen 80.*$/    listen 80 $DEFAULT_SERVER_OPTION;/" $NGINX_SITE_FILENAME
    else
        sed -i "/listen 80/a\
\    server_name $HOST;
" $NGINX_SITE_FILENAME
    fi
    ln -nsf "$NGINX_SITE_FILENAME" "$NGINX_SITE_LINK"
    make_log_directory
    /etc/init.d/nginx restart >/dev/null
    echo $DONE_MSG
}

install_sysvinit_script() {
    SYSVINIT_FILENAME=/etc/init.d/$SITE
    cp $CONF_DIRECTORY/sysvinit.example $SYSVINIT_FILENAME
    sed -i "s,/var/www/$SITE,$DIRECTORY,g" $SYSVINIT_FILENAME
    sed -i "s/^ *USER=.*/USER=$UNIX_USER/" $SYSVINIT_FILENAME
    chmod a+rx $SYSVINIT_FILENAME
    update-rc.d $SITE start 20 2 3 4 5 . stop 20 0 1 6 .
    /etc/init.d/$SITE restart
}

install_website_packages() {
    echo "Installing packages from repository packages file... "
    EXACT_PACKAGES="$CONF_DIRECTORY/packages.$DISTRIBUTION-$DISTVERSION"
    PRECISE_PACKAGES="$CONF_DIRECTORY/packages.ubuntu-precise"
    GENERIC_PACKAGES="$CONF_DIRECTORY/packages"
    # If there's an exact match for the distribution and release, use that:
    if [ -e "$EXACT_PACKAGES" ]
    then
        PACKAGES_FILE="$EXACT_PACKAGES"
    # Otherwise, if this is Ubuntu, and there's a version specifically
    # for precise, use that:
    elif [ x"$DISTRIBUTION" = x"ubuntu" ] && [ -e "$PRECISE_PACKAGES" ]
    then
        PACKAGES_FILE="$PRECISE_PACKAGES"
    else
        PACKAGES_FILE="$GENERIC_PACKAGES"
    fi
    DEBIAN_FRONTEND=noninteractive \
      xargs -a "$PACKAGES_FILE" apt-get -qq -y install >/dev/null
    echo "  $DONE_MSG"
}

overwrite_rc_local() {
    EC2_REWRITE="$BIN_DIRECTORY/ec2-rewrite-conf"
    # Some scripts have an ec2-rewrite-conf script that can be used to
    # update the hostnme on reboot - if that's present, use it,
    # otherwise the alternative is to re-run the install script:
    if [ -f "$EC2_REWRITE" ]
    then
        cat > /etc/rc.local <<EOF
#!/bin/sh -e

su -l -c '$EC2_REWRITE' $UNIX_USER
/etc/init.d/$SITE restart

exit 0
EOF
    else
        cat > /etc/rc.local <<EOF
#!/bin/sh -e

xargs -0 -a '$COPIED_ARGUMENTS' '$COPIED_SCRIPT'

GENERAL_FILE='$CONF_DIRECTORY/general.yml'
OLD_HOST_FILE='$OLD_HOST_FILE'

if [ -f "\$GENERAL_FILE" ] && [ -f "\$OLD_HOST_FILE" ]
then
    NEW_HOST="\$(curl -s http://169.254.169.254/latest/meta-data/public-hostname)"
    OLD_HOST="\$(cat "\$OLD_HOST_FILE")"
    sed -i "s/\$OLD_HOST/\$NEW_HOST/g" "\$GENERAL_FILE"
fi
EOF
    fi
    chmod a+rx /etc/rc.local
}

generate_locales
set_locale

add_unix_user

update_apt_sources

# And remove one crippling package, if it's installed:
apt-get -qq remove -y --purge apt-xapian-index >/dev/null || true

clone_or_update_repository

chown -R "$UNIX_USER"."$UNIX_USER" "$DIRECTORY"

# Check that we have a conf or config directory:
if [ -d "$REPOSITORY/conf" ]
then
    CONF_DIRECTORY="$REPOSITORY/conf"
elif [ -d "$REPOSITORY/config" ]
then
    CONF_DIRECTORY="$REPOSITORY/config"
else
    error_msg "No conf or config directory was found in $REPOSITORY"
    exit 1
fi

# Check that we can find the bin or script directory:
if [ -d "$REPOSITORY/bin" ] && [ -f "$REPOSITORY/bin/site-specific-install.sh" ]
    then
      BIN_DIRECTORY="$REPOSITORY/bin"
fi

if [ -d "$REPOSITORY/script" ] && [ -f "$REPOSITORY/script/site-specific-install.sh" ]
    then
      BIN_DIRECTORY="$REPOSITORY/script"
fi

if [ -f "$BIN_DIRECTORY/site-specific-install.sh" ]
    then
        . "$BIN_DIRECTORY/site-specific-install.sh"
    else
        error_msg "No bin or script directory was found in $REPOSITORY"
fi
