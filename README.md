# eSync

    otp21.2+
    Erlang即时重新编译和重新加载！

## 基于 [fsnotify](https://github.com/fsnotify/fsnotify) 跨平台文件系统通知。

## 改造自 [sync](https://github.com/rustyio/sync)

## 封装的监听文件项目[fileSync](https://github.com/SisMaker/fileSync) 如果要自己构建执行文件, 拉取监听文件项目, 然后 go build 复制执行文件到该工程的 priv 目录即可

# 特点

    本项目实现了自带编译与加载功能，另外支持额外的编译命令，但是执行额外的编译命令是通过os:cmd(),会阻塞VM不是很建议使用.
    启动后，eSync会收集监听目录下的源文件和编译选项等的信息。
    不仅适用于开发模式，也可以在生产环境中运行。
    注意：linux下拉取项目后  需要给priv目录下的执行文件添加执行权限

# 使用

    启动自动编译与加载 
        eSync:run().
    暂停自动编译与加载
        eSync:pause().
    停止自动编译应用
        eSync:stop().    
    启动或者关闭集群同步加载
        eSync:swSyncNode(TrueOrFalse).
    设置编译与加载日志提示
        eSync:setLog(Val).
    设置加载后的钩子函数(支持匿名函数， {Mod, Fun}(Fun函数只有一个参数)格式， 以及他们的列表组合）
        eSync:setOnsync(FunOrFuns).   

# 配置说明

    参见eSync.sample.config
    默认配置为
    [ 
        {eSync，
    	    [
                {compileCmd, undefined},
                {extraDirs, undefined}
                {log, all},     
                {descendant, fix}
            ]      
        } 
    ]