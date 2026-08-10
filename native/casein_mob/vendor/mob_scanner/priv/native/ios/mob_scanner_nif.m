/* mob_scanner_nif — iOS QR/barcode scanner tier-1 plugin NIF (Objective-C).
 *
 * Casein vendor of mob_scanner 0.1.1 with DairyPhone (#457) camera fix:
 * prefer a QR metadata object over the first non-QR barcode, and honor the
 * formats JSON argument so formats: [:qr] does not leave barcode types armed.
 */
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <erl_nif.h>

static void scan_send2(const ErlNifPid *pid, const char *a1, const char *a2) {
    ErlNifEnv *e = enif_alloc_env();
    ERL_NIF_TERM msg = enif_make_tuple2(e, enif_make_atom(e, a1), enif_make_atom(e, a2));
    enif_send(NULL, (ErlNifPid *)pid, e, msg);
    enif_free_env(e);
}

static UIViewController *scan_root_vc(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            UIWindow *w = ws.keyWindow ?: ws.windows.firstObject;
            if (w.rootViewController)
                return w.rootViewController;
        }
    }
    return nil;
}

@interface MobScannerVC : UIViewController <AVCaptureMetadataOutputObjectsDelegate>
@property(nonatomic) ErlNifPid pid;
@property(nonatomic, strong) AVCaptureSession *session;
@property(nonatomic, strong) AVCaptureVideoPreviewLayer *preview;
@property(nonatomic, copy) NSArray<AVMetadataObjectType> *objectTypes;
@end

static MobScannerVC *g_scanner_vc = nil;

static NSArray<AVMetadataObjectType> *MobScannerObjectTypesFromJSON(NSString *formatsJSON) {
    static NSArray<AVMetadataObjectType> *allTypes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      allTypes = @[
          AVMetadataObjectTypeQRCode, AVMetadataObjectTypeEAN13Code,
          AVMetadataObjectTypeEAN8Code, AVMetadataObjectTypeCode128Code,
          AVMetadataObjectTypeCode39Code, AVMetadataObjectTypeAztecCode,
          AVMetadataObjectTypePDF417Code, AVMetadataObjectTypeDataMatrixCode
      ];
    });

    if (formatsJSON.length == 0) {
        return allTypes;
    }

    NSData *data = [formatsJSON dataUsingEncoding:NSUTF8StringEncoding];
    id decoded = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![decoded isKindOfClass:[NSArray class]] || [decoded count] == 0) {
        return allTypes;
    }

    NSMutableArray<AVMetadataObjectType> *types = [NSMutableArray array];
    for (id item in decoded) {
        if (![item isKindOfClass:[NSString class]]) {
            continue;
        }
        NSString *name = [(NSString *)item lowercaseString];
        if ([name isEqualToString:@"qr"] || [name isEqualToString:@"qr_code"] ||
            [name isEqualToString:@"qrcode"]) {
            [types addObject:AVMetadataObjectTypeQRCode];
        } else if ([name isEqualToString:@"ean13"]) {
            [types addObject:AVMetadataObjectTypeEAN13Code];
        } else if ([name isEqualToString:@"ean8"]) {
            [types addObject:AVMetadataObjectTypeEAN8Code];
        } else if ([name isEqualToString:@"code128"]) {
            [types addObject:AVMetadataObjectTypeCode128Code];
        } else if ([name isEqualToString:@"code39"]) {
            [types addObject:AVMetadataObjectTypeCode39Code];
        } else if ([name isEqualToString:@"aztec"]) {
            [types addObject:AVMetadataObjectTypeAztecCode];
        } else if ([name isEqualToString:@"pdf417"]) {
            [types addObject:AVMetadataObjectTypePDF417Code];
        } else if ([name isEqualToString:@"data_matrix"] ||
                   [name isEqualToString:@"datamatrix"]) {
            [types addObject:AVMetadataObjectTypeDataMatrixCode];
        }
    }

    return types.count > 0 ? [types copy] : allTypes;
}

static AVMetadataMachineReadableCodeObject *MobScannerPreferredCode(
    NSArray<__kindof AVMetadataObject *> *metas) {
    AVMetadataMachineReadableCodeObject *fallback = nil;
    for (AVMetadataObject *object in metas) {
        if (![object isKindOfClass:[AVMetadataMachineReadableCodeObject class]]) {
            continue;
        }
        AVMetadataMachineReadableCodeObject *code =
            (AVMetadataMachineReadableCodeObject *)object;
        if (code.stringValue.length == 0) {
            continue;
        }
        if ([code.type isEqualToString:AVMetadataObjectTypeQRCode]) {
            return code;
        }
        if (!fallback) {
            fallback = code;
        }
    }
    return fallback;
}

static NSString *MobScannerTypeName(AVMetadataObjectType type) {
    if ([type isEqualToString:AVMetadataObjectTypeEAN13Code])
        return @"ean13";
    if ([type isEqualToString:AVMetadataObjectTypeEAN8Code])
        return @"ean8";
    if ([type isEqualToString:AVMetadataObjectTypeCode128Code])
        return @"code128";
    if ([type isEqualToString:AVMetadataObjectTypeCode39Code])
        return @"code39";
    if ([type isEqualToString:AVMetadataObjectTypeAztecCode])
        return @"aztec";
    if ([type isEqualToString:AVMetadataObjectTypePDF417Code])
        return @"pdf417";
    if ([type isEqualToString:AVMetadataObjectTypeDataMatrixCode])
        return @"data_matrix";
    return @"qr";
}

@implementation MobScannerVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    NSError *err = nil;
    AVCaptureDevice *dev = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    AVCaptureDeviceInput *inp = [AVCaptureDeviceInput deviceInputWithDevice:dev error:&err];
    if (!inp) {
        scan_send2(&_pid, "scan", "not_available");
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    self.session = [[AVCaptureSession alloc] init];
    [self.session addInput:inp];
    AVCaptureMetadataOutput *out = [[AVCaptureMetadataOutput alloc] init];
    [self.session addOutput:out];
    [out setMetadataObjectsDelegate:self queue:dispatch_get_main_queue()];
    NSArray<AVMetadataObjectType> *requested =
        self.objectTypes ?: MobScannerObjectTypesFromJSON(nil);
    NSMutableArray<AVMetadataObjectType> *available = [NSMutableArray array];
    for (AVMetadataObjectType type in requested) {
        if ([out.availableMetadataObjectTypes containsObject:type]) {
            [available addObject:type];
        }
    }
    out.metadataObjectTypes = available.count > 0 ? available : @[ AVMetadataObjectTypeQRCode ];
    self.preview = [AVCaptureVideoPreviewLayer layerWithSession:self.session];
    self.preview.videoGravity = AVLayerVideoGravityResizeAspectFill;
    self.preview.frame = self.view.bounds;
    [self.view.layer addSublayer:self.preview];
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:@"Cancel" forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.frame = CGRectMake(16, 60, 80, 44);
    [btn addTarget:self action:@selector(cancel) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:btn];
    [self.session startRunning];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.preview.frame = self.view.bounds;
}
- (void)cancel {
    [self.session stopRunning];
    scan_send2(&_pid, "scan", "cancelled");
    [self dismissViewControllerAnimated:YES completion:nil];
    g_scanner_vc = nil;
}
- (void)captureOutput:(AVCaptureOutput *)out
    didOutputMetadataObjects:(NSArray<__kindof AVMetadataObject *> *)metas
              fromConnection:(AVCaptureConnection *)conn {
    (void)out;
    (void)conn;
    AVMetadataMachineReadableCodeObject *code = MobScannerPreferredCode(metas);
    if (!code) {
        return;
    }
    [self.session stopRunning];
    NSString *val = code.stringValue;
    NSString *typ = MobScannerTypeName(code.type);
    ErlNifPid p = self.pid;
    g_scanner_vc = nil;
    [self dismissViewControllerAnimated:YES
                             completion:^{
                               ErlNifEnv *e = enif_alloc_env();
                               const char *cval = val.UTF8String;
                               const char *ctyp = typ.UTF8String;
                               if (!cval || !ctyp) {
                                   enif_free_env(e);
                                   return;
                               }
                               ErlNifBinary vb;
                               size_t len = strlen(cval);
                               enif_alloc_binary(len, &vb);
                               memcpy(vb.data, cval, len);
                               ERL_NIF_TERM keys[2] = {enif_make_atom(e, "type"),
                                                       enif_make_atom(e, "value")};
                               ERL_NIF_TERM vals[2] = {enif_make_atom(e, ctyp),
                                                       enif_make_binary(e, &vb)};
                               ERL_NIF_TERM map;
                               enif_make_map_from_arrays(e, keys, vals, 2, &map);
                               ERL_NIF_TERM msg = enif_make_tuple3(
                                   e, enif_make_atom(e, "scan"), enif_make_atom(e, "result"), map);
                               enif_send(NULL, &p, e, msg);
                               enif_free_env(e);
                             }];
}
@end

static ERL_NIF_TERM nif_scanner_scan(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifPid pid;
    enif_self(env, &pid);
    char formats_buf[512];
    NSString *formatsJSON = @"";
    if (argc >= 1 && enif_get_string(env, argv[0], formats_buf, sizeof(formats_buf), ERL_NIF_LATIN1)) {
        formatsJSON = [NSString stringWithUTF8String:formats_buf] ?: @"";
    }
    NSArray<AVMetadataObjectType> *types = MobScannerObjectTypesFromJSON(formatsJSON);
    dispatch_async(dispatch_get_main_queue(), ^{
      g_scanner_vc = [[MobScannerVC alloc] init];
      g_scanner_vc.pid = pid;
      g_scanner_vc.objectTypes = types;
      g_scanner_vc.modalPresentationStyle = UIModalPresentationFullScreen;
      [scan_root_vc() presentViewController:g_scanner_vc animated:YES completion:nil];
    });
    return enif_make_atom(env, "ok");
}

static ErlNifFunc nif_funcs[] = {
    {"scanner_scan", 1, nif_scanner_scan, 0},
};

ERL_NIF_INIT(mob_scanner_nif, nif_funcs, NULL, NULL, NULL, NULL)
