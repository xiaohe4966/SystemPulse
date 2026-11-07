#include "TemperatureProbe.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <string.h>

typedef unsigned int IOHIDEventField;

typedef void *(*CreateClientFn)(CFAllocatorRef);
typedef void (*SetMatchingFn)(void *, CFDictionaryRef);
typedef CFArrayRef (*CopyServicesFn)(void *);
typedef void *(*CopyEventFn)(void *, int64_t, int32_t, int32_t);
typedef double (*GetFloatFn)(void *, IOHIDEventField);
typedef CFTypeRef (*CopyPropertyFn)(void *, CFStringRef);

static void *client = NULL;
static CFMutableDictionaryRef matching = NULL;
static CreateClientFn createClient = NULL;
static SetMatchingFn setMatching = NULL;
static CopyServicesFn copyServices = NULL;
static CopyEventFn copyEvent = NULL;
static GetFloatFn getFloatValue = NULL;
static CopyPropertyFn copyProperty = NULL;
static int loaded = 0;

static void loadSymbols(void) {
    if (loaded) return;
    loaded = 1;

    void *handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (handle == NULL) return;

    createClient = (CreateClientFn)dlsym(handle, "IOHIDEventSystemClientCreate");
    setMatching = (SetMatchingFn)dlsym(handle, "IOHIDEventSystemClientSetMatching");
    copyServices = (CopyServicesFn)dlsym(handle, "IOHIDEventSystemClientCopyServices");
    copyEvent = (CopyEventFn)dlsym(handle, "IOHIDServiceClientCopyEvent");
    getFloatValue = (GetFloatFn)dlsym(handle, "IOHIDEventGetFloatValue");
    copyProperty = (CopyPropertyFn)dlsym(handle, "IOHIDServiceClientCopyProperty");

    if (!createClient || !setMatching || !copyServices || !copyEvent || !getFloatValue) {
        client = NULL;
        return;
    }

    client = createClient(kCFAllocatorDefault);
    if (client == NULL) return;

    int page = 0xff00;      /* kHIDPage_AppleVendor */
    int usage = 0x0005;     /* AppleVendor 温度传感器 */
    CFNumberRef pageNumber = CFNumberCreate(NULL, kCFNumberSInt32Type, &page);
    CFNumberRef usageNumber = CFNumberCreate(NULL, kCFNumberSInt32Type, &usage);
    matching = CFDictionaryCreateMutable(NULL, 0,
                                         &kCFTypeDictionaryKeyCallBacks,
                                         &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(matching, CFSTR("PrimaryUsagePage"), pageNumber);
    CFDictionarySetValue(matching, CFSTR("PrimaryUsage"), usageNumber);
    CFRelease(pageNumber);
    CFRelease(usageNumber);
    setMatching(client, matching);
}

static int isBatterySensor(void *service) {
    if (copyProperty == NULL) return 0;
    CFTypeRef product = copyProperty(service, CFSTR("Product"));
    if (product == NULL) return 0;

    int isBattery = 0;
    if (CFGetTypeID(product) == CFStringGetTypeID()) {
        char name[128] = {0};
        if (CFStringGetCString((CFStringRef)product, name, sizeof(name),
                               kCFStringEncodingUTF8)) {
            isBattery = (strstr(name, "battery") != NULL ||
                         strstr(name, "gas gauge") != NULL);
        }
    }
    CFRelease(product);
    return isBattery;
}

double sp_current_temperature(void) {
    loadSymbols();
    if (client == NULL || copyServices == NULL || copyEvent == NULL ||
        getFloatValue == NULL) {
        return -1.0;
    }

    CFArrayRef services = copyServices(client);
    if (services == NULL) return -1.0;

    double maximum = -1.0;
    CFIndex count = CFArrayGetCount(services);
    for (CFIndex index = 0; index < count; index++) {
        void *service = (void *)CFArrayGetValueAtIndex(services, index);
        if (isBatterySensor(service)) continue;

        /* 15 = kIOHIDEventTypeTemperature；字段 = type << 16 */
        void *event = copyEvent(service, 15, 0, 0);
        if (event == NULL) continue;
        double value = getFloatValue(event, 15u << 16);
        CFRelease((CFTypeRef)event);

        if (value > 20.0 && value < 120.0 && value > maximum) {
            maximum = value;
        }
    }
    CFRelease(services);
    return maximum;
}
