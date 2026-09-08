// OpenTileC.h — minimal C bridge to MultitouchSupport.framework.
//
// The framework has no public headers, so we declare only what we use.
//
// MTTouch layout below was verified empirically on Apple Silicon (macOS 26)
// by dumping raw contact frames: record stride is 96 bytes; offsets for
// identifier/state/x/y/velocity/pressure/radius/angle all confirmed against
// live multi-finger data. Layout differs from pre-arm64 references (no
// internal pointer field).

#ifndef OPENTILE_C_H
#define OPENTILE_C_H

typedef struct MTDevice *MTDeviceRef;

/// One touch point, as delivered per contact frame.
typedef struct {
    int frame;              // +0   frame counter
    int pad;                // +4   zero
    double timestamp;       // +8   seconds
    int identifier;         // +16  finger id, stable while down
    int state;              // +20  1 begin · 2–3 transition · 4 contact · 5–7 lift
    int unknown1;           // +24  movement-related
    int unknown2;           // +28  observed 1 while touching
    float x;                // +32  normalized 0…1
    float y;                // +36  normalized 0…1
    float velocityX;        // +40  units/frame
    float velocityY;        // +44
    float size;             // +48  contact area proxy
    float unknown3;         // +52  observed 1.0 / 2.0
    float pressure;         // +56  0…1
    float radius;           // +60  contact ellipse major, px
    float minorRadius;      // +64  contact ellipse minor, px
    float angle;            // +68  ellipse rotation, degrees
    float unknown4[6];      // +72  tail, zeroed or telemetry
} MTTouch;                  // = 96 bytes total

/// Called per contact frame (~90–125 Hz). Return value ignored.
typedef int (*MTContactFrameCallback)(int device,
                                      MTTouch *touches,
                                      int numTouches,
                                      double timestamp,
                                      int frame);

MTDeviceRef MTDeviceCreateDefault(void);
void MTRegisterContactFrameCallback(MTDeviceRef device, MTContactFrameCallback callback);
void MTDeviceStart(MTDeviceRef device, int useThread);
void MTDeviceStop(MTDeviceRef device);
void MTDeviceRelease(MTDeviceRef device);

#endif // OPENTILE_C_H
