// SIOTimeScale.h — v2.6.0 时间源缩放引擎（OpenSpeedy 思路的 iOS 移植）
//
// 原理：fishhook 符号重绑定 + ObjC 层 swizzle，缩放目标 App「读到」的单调时间，
// 不触碰内核、渲染服务器与任何系统内部计时（等价于 OpenSpeedy 的 Ring3 时间源缩放）。
// 只缩放单调钟，绝不触碰挂钟（TLS 证书校验 / 服务器时间对账依赖真实时间）。
//
// 覆盖面（P0/P1）：
//   P0  mach_absolute_time / mach_continuous_time / clock_gettime(单调族) /
//       clock_gettime_nsec_np / CACurrentMediaTime / dispatch_time(相对延时)
//   P1  usleep / nanosleep / sleep（节拍缩短）+
//       CADisplayLink timestamp/targetTimestamp/duration（ObjC getter）+
//       NSTimer 创建参数 interval（ObjC swizzle）
// 不可达（shared cache 内部互调）：dispatch_after 内部计时、CFRunLoopTimer、
//       GCD timer source —— 这是无越狱内联 hook 前提下的硬边界。

#ifndef SIO_TIME_SCALE_H
#define SIO_TIME_SCALE_H

#import <Foundation/Foundation.h>

// 安装全部重绑/swizzle。幂等：重复调用只生效一次。
// 必须在进程早期（构造函数）调用；后续 apply 才会真正生效。
void SIO_TS_install(void);

// 应用配置。调用方必须串行（主队列/主线程）。
//   enabled    总开关（App 侧「时间源加速」；调用方应同时叠加主开关 Enabled 的与运算）
//   factor     倍率，1.0–2.0，超出会被钳制（联网超时/反作弊风险，默认封顶 2.0）
//   scaleSleep 是否缩短 usleep/nanosleep/sleep（P1 节拍加速）
//   foreground App 是否前台；非前台自动回落 1.0（后台任务/网络超时按真实时间走）
void SIO_TS_apply(BOOL enabled, double factor, BOOL scaleSleep, BOOL foreground);

#endif // SIO_TIME_SCALE_H
