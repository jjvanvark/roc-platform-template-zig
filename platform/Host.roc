## Internal hosted-effect boundary used by the platform wrappers.
##
## Applications should import `Stdout`, `Stderr` and `Kv` instead.
Host := [].{
	stderr_line! : Str => Try({}, [StderrErr(Str)])
	stdout_line! : Str => Try({}, [StdoutErr(Str)])
	kv_get! : Str, Str => Try(Str, [KvNotFound, KvErr(Str)])
	kv_put! : Str, Str, Str => Try({}, [KvErr(Str)])
}
