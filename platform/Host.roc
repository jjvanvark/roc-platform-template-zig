## Internal hosted-effect boundary used by the platform wrappers.
##
## Applications should import `Stdout`, `Stderr`, `Env`, `Kv`, `R2`, `D1`, `Pg`
## and `Queue` instead.
Host := [].{
	stderr_line! : Str => Try({}, [StderrErr(Str)])
	stdout_line! : Str => Try({}, [StdoutErr(Str)])
	kv_get! : Str, Str => Try(Str, [KvNotFound, KvErr(Str)])
	kv_put! : Str, Str, Str => Try({}, [KvErr(Str)])
	r2_get! : Str, Str => Try(List(U8), [R2NotFound, R2Err(Str)])
	r2_put! : Str, Str, List(U8) => Try({}, [R2Err(Str)])
	r2_delete! : Str, Str => Try({}, [R2Err(Str)])
	d1_query! : Str, Str, Str => Try(Str, [D1Err(Str)])
	d1_execute! : Str, Str, Str => Try(U64, [D1Err(Str)])
	pg_query! : Str, Str, Str => Try(Str, [PgErr(Str)])
	pg_execute! : Str, Str, Str => Try(U64, [PgErr(Str)])
	queue_send! : Str, Str => Try({}, [QueueErr(Str)])
	env_get! : Str => Try(Str, [EnvNotFound, EnvErr(Str)])
}
