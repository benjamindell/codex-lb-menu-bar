# Repository workflow

Unless the user explicitly says otherwise, treat every completed fix, addition,
or other change as a release-ready change:

1. Run the relevant tests and build/package checks.
2. Stage only the files owned by the task.
3. Commit the verified changes on the current branch.
4. Push that branch to its configured upstream.
5. Increment the app version as appropriate, build the release archive, and
   create a GitHub Release with the archive attached so the in-app updater can
   discover it.

If a release would require a new repository, remote, credential, signing
identity, or a materially different deployment target, stop and ask the user.
If the user says not to commit, push, or release for a particular change, that
instruction overrides this default for that change.
