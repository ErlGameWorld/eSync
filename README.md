# eSync

    otp21.2+
    Erlang's efficient automatic compile and reload tools！

## base on [fsnotify](https://github.com/fsnotify/fsnotify) Cross-platform file system notifications。

## Modified from [sync](https://github.com/rustyio/sync)

## Encapsulated monitoring file project [fileSync](https://github.com/ErlGameWorld/fileSync) If you want to build the executable file yourself, pull the monitoring file project, and then go build and copy the executable file to the priv directory of the project.

# Features

    This project implements its own compilation and loading function, and also supports additional compilation commands, but the execution of additional compilation commands is through os:cmd(), which will block the VM, which is not recommended.
    After startup, eSync will collect information about source files and compilation options in the listening directory.
    Not only is it suitable for development mode, it can also be run in a production environment.
    Note: After linux pulls down the project, you need to add execution permissions to the executable files in the priv directory

# How To Use

    Start automatic compilation and loading
        eSync:run().
    Pause automatic compilation and loading
        eSync:pause().
    Stop automatically compiling the application
        eSync:stop().    
    Start or close cluster synchronous loading
        eSync:swSyncNode(TrueOrFalse).
    Set compile and load log level
        eSync:setLog(Val).
    Set the hook function after loading (support anonymous functions, {Mod, Fun} (Fun function has only one parameter) format, and their list combination)
        eSync:setOnMSync(FunOrFuns).   
        eSync:setOnCSync(FunOrFuns). 

# Configuration instructions

    All to see: eSync.sample.config
    The default configuration is
    [ 
        {eSync，
    	    [
                {compileCmd, undefined},
                {extraDirs, undefined}
                {log, all},     
                {descendant, fix},
                {onMSyncFun, undefined},
                {onCSyncFun, undefined},
                {swSyncNode, false},
                {isJustMem, false},
                {debugInfoKeyFun, undefined}
            ]      
        } 
    ]
