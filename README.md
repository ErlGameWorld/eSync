# erlSync
改造自 [sync](https://github.com/rustyio/sync) 有兴趣可以了解一下, 本项目仅仅在此基础做了一些封装改动和优化，工作原理并无差别 
# 工作原理
    启动后，Sync会收集有关已加载模块，ebin目录，源文件，编译选项等的信息。
    然后，Sync会定期检查源文件的最后修改日期。如果自上次扫描以来文件已更改，则Sync会使用上一组编译选项自动重新编译模块。如果编译成功，它将加载更新的模块。否则，它将编译错误输出到控制台。
    同步还会定期检查任何梁文件的上次修改日期，如果文件已更改，则会自动重新加载。
    扫描过程会在运行的Erlang VM上增加1％到2％的CPU负载。已经采取了很多措施将其保持在较低水平。
    但这仅适用于开发模式，请勿在生产中运行。
    
# 使用
    启动自动编译与加载 
        erlSync:run().
    暂停自动编译与加载
        erlSync:pause().
    启动或者关闭集群同步加载
        erlSync:swSyncNode(TrueOrFalse).
    设置编译与加载日志提示
        erlSync:setLog(Val).
    设置加载后的钩子函数(支持匿名函数， {Mod, Fun}(Fun函数只有一个参数)格式， 以及他们的列表组合）
        erlSync:setOnsync(FunOrFuns).   
        
# 配置说明
    参见erlSync.sample.config
    默认配置为
    [ 
        {erlSync，
    	    [
    	        {moduleTime, 30000},
                    {srcDirTime, 5000},
                    {srcFileTime, 5000},
                    {compareBeamTime, 3000},
                    {compareSrcFileTime, 3000}, 
                    {srcDirs, undefined}
                    {log, all},     
                    {descendant, fix},
                    {onlyMods, []},
                    {excludedMods, []}
            ]      
        } 
    ]