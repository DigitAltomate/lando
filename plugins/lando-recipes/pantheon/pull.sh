#!/bin/bash

# Set option defaults
CODE=${TERMINUS_ENV:-dev}
DATABASE=${TERMINUS_ENV:-dev}
FILES=${TERMINUS_ENV:-dev}
RSYNC=false

# Set helpers
FRAMEWORK=${FRAMEWORK:-drupal}
SITE=${PANTHEON_SITE_NAME:-${TERMINUS_SITE:-whoops}}
ENV=${TERMINUS_ENV:-dev}
FILE_DUMP="/tmp/files.tar.gz"
PV=""
PULL_DB=""
PULL_FILES=""

# PARSE THE ARGZZ
while (( "$#" )); do
  case "$1" in
    -c|--code|--code=*)
      if [ "${1##--code=}" != "$1" ]; then
        CODE="${1##--code=}"
        shift
      else
        CODE=$2
        shift 2
      fi
      ;;
    -d|--database|--database=*)
      if [ "${1##--database=}" != "$1" ]; then
        DATABASE="${1##--database=}"
        shift
      else
        DATABASE=$2
        shift 2
      fi
      ;;
    -f|--files|--files=*)
      if [ "${1##--files=}" != "$1" ]; then
        FILES="${1##--files=}"
        shift
      else
        FILES=$2
        shift 2
      fi
      ;;
    --rsync)
        RSYNC=$1
        shift
      ;;
    --)
      shift
      break
      ;;
    -*|--*=)
      echo "Error: Unsupported flag $1" >&2
      exit 1
      ;;
    *)
      shift
      ;;
  esac
done

# Do some basic validation to make sure we are logged in
echo "Verifying that you are logged in and authenticated by getting info about $SITE..."
terminus site:info $SITE || exit 1
echo "Logged in as `terminus auth:whoami`"
echo "Detected that $SITE is a $FRAMEWORK site"

# Get the database
if [ "$CODE" != "none" ]; then

  # Get the git branch
  GIT_BRANCH=master

  # Make sure we are in the git root
  cd $LANDO_MOUNT

  # Fetch the origin if this is a new branch and set the branch
  if [ "$CODE" != "dev" ]; then
    git fetch origin --all
    GIT_BRANCH=$CODE
  fi

  # Checkout and pull
  echo "Pulling code..."
  git checkout $GIT_BRANCH
  git pull -Xtheirs --no-edit origin $GIT_BRANCH

fi;

# Get the database
if [ "$DATABASE" != "none" ]; then

  # Holla at @uberhacker for this fu
  # Start with this by default
  PULL_DB="$(echo $(terminus connection:info $SITE.$ENV --field=mysql_command) | sed 's,^mysql,mysqldump --no-autocommit --single-transaction --opt -Q,')"

  # Switch to drushy pull if we can
  if [ "$FRAMEWORK" != "wordpress" ]; then

    # Get drush aliases
    echo "Downloading drush aliases..."
    terminus aliases

    # Use drush if we can (this is always faster for some reason)
    if drush sa | grep @pantheon.$SITE.$ENV 2>&1; then

      # Cleaning things up for a more efficient pull
      echo "Clearing remote cache to shrink db size"
      if [ "$FRAMEWORK" == "drupal8" ]; then
        drush @pantheon.$SITE.$ENV cr all --strict=0
      else
        drush @pantheon.$SITE.$ENV cc all --strict=0
      fi

      # Build the DB command
      PULL_DB="drush @pantheon.$SITE.$DATABASE sql-dump"

    fi

  fi

  # Wake up the database so we can actually connect
  terminus env:wake $SITE.$ENV

  # Build out the rest of the command
  if command -v pv >/dev/null 2>&1; then
    PULL_DB="$PULL_DB | pv"
  fi
  PULL_DB="$PULL_DB | mysql --user=pantheon --password=pantheon --database=pantheon --host=database --port=3306"

  # Importing database
  echo "Pulling database..."
  eval "$PULL_DB"

  # Do some post DB things on WP
  if [ "$FRAMEWORK" == "wordpress" ]; then
    echo "Doing the ole post-migration search-replace on WordPress..."
    wp search-replace "http://$ENV-$SITE.pantheonsite.io" "http://$LANDO_APP_NAME.lndo.site"
  fi

fi

# Get the files
if [ "$FILES" != "none" ]; then

  # Build the rsync command
  RSYNC_CMD="rsync -rlvz \
    --size-only \
    --ipv4 \
    --progress \
    --exclude js \
    --exclude css \
    --exclude ctools \
    --exclude imagecache \
    --exclude xmlsitemap \
    --exclude backup_migrate \
    --exclude php/twig/* \
    --exclude styles \
    --exclude less \
    -e 'ssh -p 2222' \
    $ENV.$PANTHEON_SITE@appserver.$ENV.$PANTHEON_SITE.drush.in:files/ \
    $LANDO_WEBROOT/$FILEMOUNT"

  # Build the extract CMD
  if [ "$RSYNC" == "false" ]; then
    PULL_FILES="rm -f $FILE_DUMP && terminus backup:get $SITE.$FILES --element=files --to=$FILE_DUMP && mkdir -p $LANDO_WEBROOT/$FILEMOUNT &&"
    if command -v pv >/dev/null 2>&1; then
      PULL_FILES="$PULL_FILES pv $FILE_DUMP | tar xzf - -C $LANDO_WEBROOT/$FILEMOUNT --strip-components 1 &&"
    else
      PULL_FILES="$PULL_FILES tar -xzf $FILE_DUMP -C $LANDO_WEBROOT/$FILEMOUNT/ --strip-components 1 &&"
    fi
  fi

  # Add in rsync regardless
  PULL_FILES="$PULL_FILES $RSYNC_CMD"

  # Importing database
  echo "Pulling files..."
  eval "$PULL_FILES"

fi
