#!/bin/zsh

# Summary
# -------
# **pintxuos** implements a simple state machine for wacom's intuos tablet.
# States are represented by directories; Every state corresponds to one
# set of hotkeys with (optional) corresponding OLED buttons.
# It uses the sysfs interface introduced in [a recent patch][p] by _Eduard Hasenleithner_.
#
# [p]: https://patchwork.kernel.org/patch/765792/

# How to use pintxuos
# -------------------
#
# (This section is still to be written.) The basic idea is that you
# bind the buttons on your tablet to `pintxuos press N` where N
# is the number of the button counting from 1-8, starting
# from the top. The button inside the ring has the number 0.
# (This is purely a convention. The patch mentioned above
# uses numbers from 0-7, but this is accounted for.)
# Then `pintxuos` will handle dispatching key events to applications
# and changing the hotkeys and images as you switch to different sets
# of key bindings.
# One way of binding your buttons to pintxuos commands would be
# to use your window manager to bind some dummy keyboard shortcuts
# like 'Win-F*' to execute pintxuos and then bind your tablet's buttons
# to those keyboard shortcuts. The benefit is that you can use Xorg.conf
# to map those buttons as those mappings will remain the same.

# Getting it to work
# ------------------
# In my local version of the patch above I have changed every occurence
# of `S_IWUSR` to `S_IWUSR | S_IWOTH` to allow writing to the control
# files by every user. This will eventually be handled differently
# by xsetwacom some day (for example by special a setuid binary).

realpath () {
  # resolve symlinks to directories, return empty string on failure
  setopt localoptions no_shwordsplit chaselinks
  builtin cd -q $1 2>/dev/null && pwd
}

usage () {
  echo "Usage: $0 " $@ 1>&2
  exit 1
}

err () {
  echo $@ 1>&2
  exit 1
}

warn () {
  echo $@ 1>&2
}

info () {
  [[ -n $DEBUG ]] && echo $@ 1>&2
}

which xdotool >/dev/null 2>&1 || err "xdotool not found"

PROFILES=$HOME/.pintxuos
[[ -d $PROFILES ]] || err "Profile directory does not exist"
THIS=$PROFILES/this

TABLETS=(/sys/class/input/input*/led(/N))
info "$#TABLETS tablet(s) with led support found"

# Changing states
# ---------------
change_state () {
  [[ ! -e $THIS || -d $THIS && -h $THIS ]] || err "Abort: Non-symlink state found??"

  if [[ -n $1 && -d $1 ]]; then
    # Change symlink to point to new state.
    local new_state=$(realpath $1)
    info "changing to state $new_state"
    rm -f $THIS
    ln -s $new_state $THIS
  else
    return
  fi

  if [[ -x $THIS/_init ]]; then
    # call initialization script with path to this program
    # passed as first argument.
    info "calling initialization script"
    $THIS/_init $0
  fi

  (( $#TABLETS > 0 )) || return

  # LED & OLED handling
  # ===================

  if which intuos4led-img2raw >/dev/null 2>&1; then
    for img in $THIS/[1-8].png(N); do
      # Convert images to proper icon format.
      raw=${img/%.png/.raw}

      [[ -r $raw ]] && continue
      info "converting ${img##*/} to raw grayscale"

      if [[ -e $PROFILES/_lefthanded ]]; then
        intuos4led-img2raw --lefthanded $img 2>/dev/null
      else
        intuos4led-img2raw $img 2>/dev/null
      fi
    done
    # Create a blank icon to display on buttons without image.
    [[ -r $PROFILES/blank.raw ]] || intuos4led-img2raw --blank $PROFILES/blank.raw 2>/dev/null
  else
    warn "intuos4led-img2raw not found, unable to convert images"
  fi


  for tablet in $TABLETS; do
    local status_led=-1
    if [[ -r $THIS/_status ]]; then
      # To set the status led on the tablet's ring, put a number between 1 and 3 in `_status`.
      # If no such file is found, the status leds will be turned off.
      status_led=$(cat $THIS/_status)
      [[ -e $PROFILES/_lefthanded ]] && status_led=$((3-status_led))
    fi
    info "setting status led to $status_led"
    echo $status_led > $tablet/status_led_select

    for (( i=1 ; i <= 8 ; i++ )); do
      num=$((i-1))

      # Assign icons in inverse order if lefthanded.
      [[ -e $PROFILES/_lefthanded ]] && num=$((7-num))

      if [[ -r $THIS/$i.raw ]]; then
        # Display icon if found.
        info "displaying icon $i"
        cat $THIS/$i.raw > $tablet/button${num}_rawimg
      elif [[ -r $PROFILES/blank.raw ]]; then
        # Display blank icon on buttons without an image.
        cat $PROFILES/blank.raw > $tablet/button${num}_rawimg
      fi
    done
  done
}

# Initialization
# --------------
if [[ ! -e $THIS ]]; then
  if [[ -d $PROFILES/init ]]; then
    # Start in 'init' profile/state if there is no current state.
    info "No state set up."
    change_state "$PROFILES/init"
  else
    err "No state set and no 'init' profile found."
  fi
fi

# The current state has to be a symlink to a directory.
[[ -d $THIS && -h $THIS ]] || err "Invalid state"

# State machine
# -------------

# "go to state"
# =============
by_name () {
  # It is possible to switch to a specific state specified by its path.
  local new_state
  if [[ -z ${1##/*} ]]; then
    # If the new state in prefixed by `/` it is assumed to
    # be relative to the profiles directory.
    new_state="$PROFILES/${1#/}"
  else
    # Else it will be relative to the current state.
    new_state=$(realpath "$THIS/$1")
  fi

  change_state $new_state
}

# "handle hotkey"
# ===============
by_hotkey () {
  # The second possibility to change states is by invoking a hotkey.
  # Those are represented by files starting with `"N-"` inside a state directory.
  # (where N ∈ [0,8])
  matches=($THIS/$1-*(N))
  if (( $#matches == 1 )); then
    f=${matches[1]}
    if [[ -x $f && ! -d $f ]]; then
      # If there is an executable file with a matching name it will be executed.
      # (The path to this program will be passed as its first parameter)
      info "running: $f $0"
      $f $0
      return
    fi

    if [[ $f =~ ':' ]]; then
      # Else if the filename contains a colon everything up to the first `:`
      # will be stripped and the rest sent as Keysyms to the focused window.
      info "sending to active window: ${=f#*:}"
      xdotool getwindowfocus key --window "%1" --clearmodifiers ${=f#*:} # ( `${=spec}` forces word splitting!)
    fi

    if [[ -d $f ]]; then
      # If the match is a directory (or a symlink ⇒ that's how you create rings)
      # that directory will be the new state.
      # You can avoid changing states by using plain files (f.ex. created using `touch`).
      change_state $f
    fi
  else
    warn "$#matches matches found for $1 in state: $(realpath $THIS)"
  fi
}

local cmd="$1"
(( $# >= 1 )) && shift
case $cmd in
  go)
    (( $# >= 1 )) || usage "go [/]<path>"
    by_name $1
    ;;
  press)
    (( $# >= 1 )) || usage "press <#KEY>"
    by_hotkey $1
    ;;
  list)
    ls -l $(realpath $THIS)/[0-9]-*
    ;;
esac

# vim:ft=zsh
