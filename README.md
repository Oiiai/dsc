# DSC ——Linux跨平台包管理器
[下载最新版本](https://github.com/Oiiai/dsc/releases) <br />
~~懒得写README了，直接看Release页面吧~~

## 如何下载并安装
* [点这里](https://github.com/Oiiai/dsc/releases) 下载最新版本
* 下载完成后，进入存放 `dsc` 文件的文件夹
* 空白处右键，选择 **在控制台打开** *（不同桌面环境可能不一样，总之能打开终端就行）*
* 输入 `sudo chmod +x dsc` 赋权
* 输入 `sudo cp ./dsc /usr/local/bin/` 把它复制到 `/usr/local/bin/` 文件夹下
* 重新打开终端，输入 `sudo dsc` 看看能否正常运行

## 基础使用
* 使用 `sudo dsc addrepo {url} [-for {pkg name}]` 添加仓库源
* 使用 `sudo dsc rmrepo {pkg name} [{number}]` 删除软件包的第 `{number}` 个仓库源
* 使用 `sudo dsc install {pkg name}` 安装软件包
* 使用 `sudo dsc delete {pkg name}` 删除软件包
* 使用 `sudo dsc info {pkg name}` 查看软件包信息
* ...

~~其实标题写得有点问题，这个包管理器并不能做到真正“跨平台”，它只能在Linux系统上使用；但是我也懒得改了（狗头保命（（（~~
