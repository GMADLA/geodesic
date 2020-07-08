#!/bin/bash

function sync_clocks() {
	# Use a timeout due to slow clock reads on EC2 (10 seconds).
	# Fixes: hwclock: select() to /dev/rtc0 to wait for clock tick timed out
	hwclock_time=$(timeout 1.5 hwclock -r)

	# Sync the clock in the Docker Virtual Machine to the system's hardware clock to avoid time drift.
	# Assume whichever clock is behind by more than 10 seconds is wrong, since virtual clocks
	# almost never gain time.
	if [ -n "${hwclock_time}" ]; then
		let diff=$(date '+%s')-$(date -d "${hwclock_time}" '+%s')
		echo "* Docker clock is ${diff} seconds behind Host clock"
		if [ $diff -gt 2 ]; then
			if hwclock -w >/dev/null 2>&1; then
				echo "* $(green Successfully synced clocks)"
				let diff=$(date '+%s')-$(date -d "$(timeout 5 hwclock -r)" '+%s')
				echo "* $(green Docker clock is now ${diff} seconds behind Host clock)"
			else
				echo "* $(yellow Failed to set Docker clock from Host clock)"
			fi
		elif [ $diff -lt -2 ]; then
			# (Only works in privileged mode)
			if hwclock -2 >/dev/null 2>&1; then
				echo "* $(green Successfully synced clocks)"
				let diff=$(date '+%s')-$(date -d "$(timeout 5 hwclock -r)" '+%s')
				echo "* $(green Docker clock is now ${diff} seconds behind Host clock)"
			else
				echo "* $(yellow Failed to set Host clock from Docker clock)"
			fi
		fi
	else
		echo "* $(yellow Unable to read hardware clock)"
	fi
}

if [ "${AWS_SSO_ENABLED:-true}" == "true" ]; then
    if ! which aws2-wrap >/dev/null; then
		echo "aws2-wrap not installed"
		exit 1
	fi

	if [ -n "${AWS_SSO}" ]; then
		export ASSUME_ROLE=${AWS_SSO}
	fi

	PROMPT_HOOKS+=("aws_sso_prompt")
	function aws_sso_prompt() {
		if [ -z "${AWS_SSO}" ]; then
			echo -e "-> Run '$(green aws-sso)' to login to AWS"
		fi
	}

	function choose_role_interactive() {
		_preview="${FZF_PREVIEW:-crudini --format=ini --get "$AWS_CONFIG_FILE" 'profile {}'}"
		crudini --get "${AWS_CONFIG_FILE}" |
			awk -F ' ' '{print $2}' |
			fzf \
				--height 30% \
				--preview-window right:70% \
				--reverse \
				--select-1 \
				--prompt='-> ' \
				--header 'Select AWS profile' \
				--query "${ASSUME_ROLE_INTERACTIVE_QUERY:-${NAMESPACE}-${STAGE}-}" \
				--preview "$_preview"
	}

	function choose_role() {
		if [ "${ASSUME_ROLE_INTERACTIVE:-true}" == "true" ]; then
			echo "$(choose_role_interactive)"
		else
			echo "${AWS_DEFAULT_PROFILE}"
		fi
	}

    function aws-access-token () {
        cat $(ls -1d ~/.aws/sso/cache/* | grep -v botocore) |  jq -r "{accessToken} | .[]"
    }

	# Start a shell or run a command with an assumed role
	function _aws_sso_assume_role() {
		# Do not allow nested roles
		if [ -n "${AWS_SSO}" ]; then
			# There is an exception to the "Do not allow nested roles" rule.
			# If we are in the current role because we are piggybacking off of an aws credential server
			# started by another process, then it is safe to allow "nesting" because we are not really in
			# an aws shell to start with. We have to allow this (a) in order to assume a role other
			# than the one the credential server is serving and (b) to continue to be able to work if
			# the process that started the server ends and takes the credential server with it.
			if [ "$SHLVL" -eq 1 ]; then
				# Save the current values of AWS_SSO
				local aws_sso="$AWS_SSO"
				# Be sure to restore the values of AWS_SSO when
				# this function returns, regardless of how it returns (e.g. in case of errors).
				trap 'export AWS_SSO="$aws_sso"' RETURN
				unset AWS_SSO
            fi
		fi

		role=${1:-$(choose_role)}

		if [ -z "${role}" ]; then
			echo "Usage: aws-sso [role]"
			return 1
		fi

		if [ "${DOCKER_TIME_DRIFT_FIX:-true}" == "true" ]; then
			sync_clocks
		fi

		shift
		if [ $# -eq 0 ]; then
			aws sso login --profile $role
            eval "$(aws2-wrap --export)"
            AWS_SSO="${role}"
		fi
	}

	function aws-sso() {
		_aws_sso_assume_role $*
	}

fi
