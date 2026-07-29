# Test evidence workflow

Router and AP evidence must be created under a unique remote directory:

```text
/tmp/mervlan_tmp/evidence/<test-run-id>/
```

Required sequence:

1. Create the unique remote directory.
2. Write logs, status, hashes, and metadata beneath it.
3. Print the exact path and test result.
4. Download the directory to `dev-tools/evidence/<test-run-id>/`.
5. Verify the local copy and expected files.
6. Delete the remote directory only after verification succeeds.

If verification fails, retain the remote evidence and report that cleanup is
still required. Raw evidence is ignored by Git. Redact secrets, credentials,
client identifiers, and unnecessary full configuration dumps before sharing.
