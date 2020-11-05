# The format for cluster name inputs and outputs is as follows:
#
#   [(v3|v4):][ENVIRONMENT:]CLUSTER_NAME
#   |------- prefix -------|
#
# The ENVIRONMENT prefix is only valid for v4 clusters.
# The ENVIRONMENT prefix may be any of:
#
#   production, prod, prd == ocm production environment
#     staging, stage, stg == ocm staging environment
#        integration, int == ocm integration environment
#
# If the version prefix is omitted but an ENVIRONMENT prefix is
# specified, such as "prod:cluster-name", then v4 is implied.

XDG_CACHE_HOME=${XDG_CACHE_HOME:-$HOME/.cache}
XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}

# cluster_prefix: $1:cluster_name
# Prints the prefix part of a cluster name argument.
function cluster_prefix {
  local pattern="^(v3:|v4:|(v4:)?production:|(v4:)?prod:|(v4:)?prd:|(v4:)?staging:|(v4:)?stage:|(v4:)?stg:|(v4:)?integration:|(v4:)?int:)"
  grep --extended-regexp --only-matching $pattern <<< "$1"
}

# cluster_from_cache_file: $1:cache_file
# Prints the full cluster name given its cache file path and
# returns 0, or returns 1 if the cache file path is invalid.
# For brevity, the ENVIRONMENT prefix uses the 3-letter variant.
function cluster_from_cache_file {
  if [[ -f $1 ]]
  then
    local cache_file=$(realpath $1)
    case $(dirname $cache_file) in
      $XDG_CACHE_HOME/sre/clusters/v3)
        echo "v3:$(basename $cache_file)"
        return 0
        ;;
      $XDG_CACHE_HOME/ocm/production/clusters)
        echo "v4:prd:$(basename $cache_file)"
        return 0
        ;;
      $XDG_CACHE_HOME/ocm/staging/clusters)
        echo "v4:stg:$(basename $cache_file)"
        return 0
        ;;
      $XDG_CACHE_HOME/ocm/integration/clusters)
        echo "v4:int:$(basename $cache_file)"
        return 0
        ;;
    esac
  fi
  return 1
}

# cluster_cache_files: $1:cluster_name
# Prints a list of cache files matching a cluster name argument.
# The cluster name argument may be incomplete, specifying only the
# prefix part (see above).  The cluster name argument may also be
# followed by a wildcard character '*'.
function cluster_cache_files {
  local prefix=$(cluster_prefix $1)
  local cluster_name=${1#$prefix}${2:-}
  local cluster_version
  local cluster_environ

  case $prefix in
    v3:)
      cluster_version=v3
      ;;
    v4:)
      cluster_version=v4
      ;;
    v4:production:|v4:prod:|v4:prd:|production:|prod:|prd:)
      cluster_version=v4
      cluster_environ=production
      ;;
    v4:staging:|v4:stage:|v4:stg:|staging:|stage:|stg:)
      cluster_version=v4
      cluster_environ=staging
      ;;
    v4:integration:|v4:int:|integration:|int:)
      cluster_version=v4
      cluster_environ=integration
      ;;
    *)
      ;;
  esac

  local v3_cache_path="$XDG_CACHE_HOME/sre/clusters/v3"
  local v4_cache_path="$XDG_CACHE_HOME/ocm${cluster_environ:+/$cluster_environ}"

  if [[ "${cluster_version:-v3}" == "v3" ]] && [[ -d "$v3_cache_path" ]]
  then
    find "$v3_cache_path" -type f -name "$cluster_name"
  fi

  if [[ "${cluster_version:-v4}" == "v4" ]] && [[ -d "$v4_cache_path" ]]
  then
    find "$v4_cache_path" -type f -name "$cluster_name"
    find "$v4_cache_path" -type l -name "$cluster_name"
  fi
}

# cluster_cache_file_exact: $1: cluster_name
# Calls cluster_cache_files with the given cluster name argument.
# Prints the matching cluster name and returns 0 if there is a single
# match.  Otherwise prints an error message to stderr and returns 1.
# This ensures a cluster name argument is valid and unambiguous.
function cluster_cache_file_exact {
  local match
  local matches=( $(cluster_cache_files $1) )
  case ${#matches[@]} in
    0)
      echo "Invalid identifier '$1'" > /dev/stderr
      return 1
      ;;
    1)
      echo ${matches[0]}
      ;;
    *)
      echo "Ambiguous identifier '$1' matches ${#matches[@]} clusters:" > /dev/stderr
      for match in ${matches[@]}
      do
        echo $(cluster_from_cache_file $match) > /dev/stderr
      done
      return 1
      ;;
  esac
}

# cluster_completion: $1:cluster_name
# Prints a list of cluster names that match a possibly incomplete
# cluster name argument as described in cluster_cache_files.  This
# function is used for shell completion of cluster name arguments.
function cluster_completion {
  local match
  local prefix=$(cluster_prefix $1)
  for match in $(cluster_cache_files $1 '*')
  do
    echo $prefix$(basename $match)
  done
}

# setup_hive_oc_for: $1:ocm_clusterid
# Sets up access to a cluster's Hive cluster by opening an SSH
# tunnel if necessary, and defining a function named "hive_oc"
# that's a drop-in replacement for "oc" but configured for the
# Hive cluster.  Works for both v3 and v4 Hive clusters.  Note,
# the SSH tunnel is automatically closed through an EXIT trap.
function setup_hive_oc_for {
  local hive_cluster_json=$(hive-cluster $1)
  local hive_cluster_id=$(jq --raw-output .id <<< $hive_cluster_json)
  local hive_cluster_name=$(jq --raw-output .display_name <<< $hive_cluster_json)

  case $hive_cluster_name in
    # Hive clusters hosted on OSDv3
    hive-integration|hive-production|hive-stage)
      local ssh_address=root@${hive_cluster_name}-master
      local ssh_options="-o StrictHostKeyChecking=no"
      case $(hostname) in
        bastion-nasa-*.ops.openshift.com)
          ;;
        *)
          ssh_options+=" -J bastion-nasa-1.ops.openshift.com"
          ;;
      esac
      eval "function hive_oc { ssh $ssh_address $ssh_options oc \$@; }"
      ;;

    *)
      local socket_dir=$XDG_RUNTIME_DIR/ssh
      local control_path=$socket_dir/%h.sock
      local ocm_production_dir=$XDG_CONFIG_HOME/ocm/production
      local kubeconfig=$ocm_production_dir/clusters/$hive_cluster_name
      local address=$(OCM_CONFIG=$ocm_production_dir/config sshaddress $hive_cluster_id)
      local socks_proxy_port=$(find-proxy-port $hive_cluster_id)
      local socks_proxy=socks5://localhost:$socks_proxy_port
      mkdir --parents $socket_dir
      mkdir --parents $(dirname $kubeconfig)
      touch $kubeconfig
      trap "ssh -q -O exit -o ControlPath=$control_path $address" EXIT
      ssh -4fq -D $socks_proxy_port -o ControlMaster=yes -o ControlPath=$control_path $address true > /dev/null
      OCM_CONFIG=$ocm_production_dir/config KUBECONFIG=$kubeconfig \
        srelogin --cluster=$hive_cluster_id --socks-proxy=$socks_proxy > /dev/null
      eval "function hive_oc { KUBECONFIG=$kubeconfig HTTPS_PROXY=$socks_proxy oc \$@; }"
      hive_oc adm groups add-users osd-sre-cluster-admins $(hive_oc whoami) > /dev/null
      ;;
  esac
  export -f hive_oc
}
