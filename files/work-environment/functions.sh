XDG_CACHE_HOME=${XDG_CACHE_HOME:-$HOME/.cache}

function cluster_prefix {
  local pattern="^(v3:|v4:|(v4:)?production:|(v4:)?prod:|(v4:)?prd:|(v4:)?staging:|(v4:)?stage:|(v4:)?stg:|(v4:)?integration:|(v4:)?int:)"
  grep --extended-regexp --only-matching $pattern <<< "$1"
}

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

function cluster_cache_files {
  # Cluster name format: [v3:|v4:][ENVIRONMENT:]NAME
  # Note: "ENVIRONMENT:NAME" implies "v4:ENVIRONMENT:NAME"
  #       "v3:ENVIRONMENT:NAME" is invalid.

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

function cluster_completion {
  local match
  local prefix=$(cluster_prefix $1)
  for match in $(cluster_cache_files $1 '*')
  do
    echo $prefix$(basename $match)
  done
}
