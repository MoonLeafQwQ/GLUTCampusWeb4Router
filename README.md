# GLUTCampusWeb4Router
适用于基于Linux（例如OpenWRT）的路由用于登录GLUT校园网的脚本

Vibe了一个用来扔到路由来防止自己掉线，推荐搭配自动任务（cron）使用，例如你把脚本扔到了路由的/root/，想让他在7点至22点59分运行，那你可以在自动任务这里写：
* `* 7-22 * * * /root/login.sh`


感谢 HWinZnieJ 大佬的教程，加上AI才能做出这个脚本
具体原理参照这篇文章：https://www.bilibili.com/opus/646733491161006112
如果需要其它平台的自动登录可以看一下这个项目：https://github.com/GLUT-LUG/GLUT-CampusNetwork

# 简介
这是一个基于Openwrt路由的自动登录脚本，模拟浏览器向 Dr.COM eportal 网关发送 HTTP 登录请求
需要wget / ping （当然你也可以去除wget部分，硬编码rcn实测没问题）

整体工作流程 (每次被 cron 调用时):

先PING阿里DNS来检测是否在线
（ICMP在未登录的时候是发不出去的，但是dns port 53是可以请求的）
探测期间在线 → 直接退出
探测到离线 → do_login 发起登录
	如果登录失败，根据响应判断是什么情况来判断是否继续登录还是直接退出
	响应解析与处理:
		result = 1 → 登录成功
		msga 含 "clientip online"  → 本机IP已有在线会话, 不再重复登录
		msga 含 "error5 waitsec<3" → 触发频繁登录限制 (与上次登录间隔 <3 秒),本轮先等 5 秒再试第 2 次，如果再次登录而再次失败，脚本则会退出
		其余情况 → 记日志失败, 等下一分钟 cron 再试
		
使用脚本前==必须配置==的参数：
USERNAME:校园网账号
PASSWORD:校园网密码
ISP:对应运营商，0 = 校园网，1 = 电信，2 = 移动， 3 = 联通，4 = 广电
