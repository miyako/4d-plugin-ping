# 4d-plugin-ping
an alternative to NET_Ping (Internet Commands)

Example
---
```
  //enhanced version of NET_Ping; works on Windows 7 x64 
$error:=HOST Ping ("www.google.com";$resposes)
  //$resposes{1}=64 bytes from 74.125.235.176: icmp_seq=1 ttl=51 time=937.533 ms
  //etc...

If (False)
  //optionally set the number of attempts, timelimit in seconds. 
$error:=HOST Ping ("www.google.com";$resposes;$count;$timelimit)
end if
```
