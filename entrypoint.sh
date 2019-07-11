#!/bin/bash

set -e

PR_NUMBER=$(jq -r ".pull_request.number" "$GITHUB_EVENT_PATH")
REPO_FULLNAME=$(jq -r ".repository.full_name" "$GITHUB_EVENT_PATH")
TOKEN=${TOKEN:-$GITHUB_TOKEN}

echo "Collecting information about PR #$PR_NUMBER of $REPO_FULLNAME..."

if [[ -z "$TOKEN" ]]; then
	echo "Set the TOKEN or GITHUB_TOKEN env variable."
	exit 1
fi

if [[ -z "$GIT_USER" ]]; then
	echo "Set the GIT_USER env variable."
	exit 1
fi

if [[ -z "$GIT_EMAIL" ]]; then
	echo "Set the GIT_EMAIL env variable."
	exit 1
fi

URI=https://api.github.com
API_HEADER="Accept: application/vnd.github.v3+json"
EXTRA_API_HEADER="Accept: application/vnd.github.v3+json; application/vnd.github.antiope-preview+json"
AUTH_HEADER="Authorization: token $TOKEN"

main () {
  pull_request=$(curl -X GET -s -H "${AUTH_HEADER}" -H "${API_HEADER}" \
    "${URI}/repos/$REPO_FULLNAME/pulls/$PR_NUMBER")

  rebaseable=$(echo ${pull_request} | jq -r ".rebaseable")
  mergeable_state=$(echo ${pull_request} | jq -r ".mergeable_state")
  labels=$(echo ${pull_request} | jq -r ".labels")

  stop_label="${LABEL:-QA needed}"
  min_approved="${MIN_APPROVED:-1}"

  if [ "$mergeable_state" = "behind" ] && [ "$rebaseable" = true ]
  then
    echo "Branch is behind on master, I'm rebasing it."

    base_repo=$(echo "$pull_request" | jq -r .base.repo.full_name)
    base_branch=$(echo "$pull_request" | jq -r .base.ref)
   
    echo "PR is behind on $base_repo, rebasing..."
   
    if [[ -z "$base_branch" ]]; then
      echo "Cannot get base branch information for PR #$PR_NUMBER!"
      echo "API response: $pull_request"
      exit 1
    fi
   
    head_repo=$(echo "$pull_request" | jq -r .head.repo.full_name)
    head_branch=$(echo "$pull_request" | jq -r .head.ref)
   
    echo "Base branch for PR #$PR_NUMBER is $base_branch"
   
    if [[ "$base_repo" != "$head_repo" ]]; then
      echo "PRs from forks are not supported at the moment."
      exit 1
    fi
   
    git remote set-url origin https://x-access-token:$TOKEN@github.com/$REPO_FULLNAME.git
    git config --global user.name "$GIT_USER"
    git config --global user.email "$GIT_EMAIL"
   
    set -o xtrace
   
    # make sure branches are up-to-date
    git fetch origin $base_branch
    git fetch origin $head_branch
   
    current_branch=$(git symbolic-ref --short -q HEAD)
    if [[ "$current_branch" != "$head_branch" ]]
    then
      echo "Checking out the correct branch"
      git checkout -b $head_branch origin/$head_branch
    fi
   
    # do the rebase
    git rebase origin/$base_branch
   
    # safely push back
    git push --force-with-lease --set-upstream origin $head_branch
   
    echo "rebased!"

  elif [ "$mergeable_state" = "behind" ] && [ "$rebaseable" = false ] || [ "$mergeable_state" = "dirty" ]  
  then
    echo "Merge conflicts while rebasing, needs manual input"
    curl -sSL -H "${AUTH_HEADER}" -H "${EXTRA_API_HEADER}" \
      -d '{"body":"![no conflict](https://media.giphy.com/media/rpH77eCfRjX32/giphy.gif)\nA conflict stopped me from rebasing/merging this pr. \nI will continue after this is resolved"}' \
      -H "Content-Type: application/json" \
      -X POST \
      "${URI}/repos/$REPO_FULLNAME/issues/$PR_NUMBER/comments"

  elif [ "$mergeable_state" = "blocked" ] 
  then
    echo "Pull request is currently blocked"
    reviews_request=$(curl -X GET -s -H "${AUTH_HEADER}" -H "${API_HEADER}" \
      "${URI}/repos/$REPO_FULLNAME/pulls/$PR_NUMBER/reviews")

    times_approved=$(echo ${reviews} | jq  '[.[] | select(.state=="APPROVE")] | length')
    times_changes=$(echo ${reviews} | jq  '[.[] | select(.state=="CHANGES_REQUESTED")] | length')
    times_dismissed=$(echo ${reviews} | jq  '[.[] | select(.state=="DISMISSED")] | length')

    approved=()

    reviews=$(echo "$reviews_request" | jq --raw-output '.[] | {state: .state, id: .user.id} | @base64')
	  for r in $reviews; do
      review="$(echo "$r" | base64 --decode)"
		  state=$(echo "$review" | jq --raw-output '.state')
		  user_id=$(echo "$review" | jq --raw-output '.id')

      if [ "$state" = "APPROVED" ]
      then
        approved+=($user_id)
      else
        for i in "${!approved[@]}"; do
          if [[ ${approved[i]} = "$user_id" ]]; then
            unset 'approved[i]'
          fi
        done
      fi
    done

    if [ ${#approved[@]} -ge $min_approved ] 
    then
      echo "Pull request is already approved so lets wait for the checks to finish"
      sleep 60
      main
    fi

    exit 0

  elif [ "$mergeable_state" = "unstable" ]  || [ "$mergeable_state" = "unknown" ]
  then
    echo "Is waiting for a process to complete, waiting..."
    echo $mergeable_state
    sleep 10
    main;

  elif [ "$mergeable_state" = "clean" ] && [ "$rebaseable" = true ]
  then
    echo "should rebase and merge"
    if [ ! -z "$LABEL" ]
    then
      blocking_label=$(echo ${labels} | jq  "[.[] | select(.name == $stop_label)] | length")

      if (($blocking_label == 0))
      then
        echo "Has a label preventing merging"
        exit 0
      fi
    fi

    merge_request=$(curl -X PUT -s -H "${AUTH_HEADER}" -H "${API_HEADER}" \
      -d '{"merge_method":"rebase"}' \
      "${URI}/repos/$REPO_FULLNAME/pulls/$PR_NUMBER/merge")
    merge_status=$(echo "$merge_request" | jq -r '.merged')

    if [ "$merge_status" = true ]
    then
      echo "Rebased and merged"
      exit 0
    else
      echo "Merge was rejected, trying from the top again"
      sleep 10
      main;
    fi
  else
    echo "Something else?"
    echo $mergeable_state
    exit 0
  fi
}

main;
