# TODO

## CREATE RUNNER

### data structures for pids & startime handling ~

Need to add pids into some data structures (ArrayList) to see check available PID,

This need to be threadsafe and will only added to the data structure if the process PID is up based on the startime.

This is my oponion i think i dont have to check if the proper number of process is started,
since i will have a thread the job of this thread if to see if the numbers of procs is valid, 
so said that i should only keep track of the pid that starttime match,
other should be considered failed and not added to the data structures holding the pids.

#### DATA STRUCTURES

For the data structures check ProcessProgram and modify also global should leave in `execution.zig`.


### discard stderr/stdout

This is an option to not allow stdout/stderr to be loged,
so if discard is set as string before running the command the stdout/stderr should be redirected,
to /dev/null.

### add environment variable

Modify the environment variable to add the one that are present in program parsing.


## WORKER

### handle restart policies

Should from the pid data structures check if some childs pid
are dead or not and restart if policies rules match.

### handle clean exit.

Should handle clean exit of process for all the process running when exiting the program.

### Abort policies 

This will cause the thread of the current service to stop if restart failed to many times.
(this should killed the thread/worker).
