# 「正在播放」的桥，宿主那一半（实时状态设计 §5）。
#
# 这个脚本本身不干活，它只提供身份：MediaRemote 只答复 Apple 签的平台二进制，
# 而 /usr/bin/perl 正是。真正的调用在 nowplaying.m 编出来的 dylib 里，
# 被装进这个进程之后就跑在它的身份底下。
#
#   /usr/bin/perl nowplaying.pl <dylib> stream
#   /usr/bin/perl nowplaying.pl <dylib> command pause
#
# stream 活到条那边关掉管道为止（stdin 读到 EOF）——**两端都不必去盯对方的 pid**。
# 其余动作由 dylib 自己 exit 收场，这里只要别抢在它前面退出。
use strict;
use warnings;
use DynaLoader;

my ($lib, $action) = @ARGV;
die "用法: nowplaying.pl <dylib> stream|command <名字>\n" unless defined $lib;
DynaLoader::dl_load_file($lib, 0x01)
    or die "装不进来: " . DynaLoader::dl_error() . "\n";

if (defined $action && $action eq 'stream') {
    while (<STDIN>) { }
} else {
    sleep 10;
}
