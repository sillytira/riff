#import "RiffBridge.h"
#include <Python/Python.h>
#include <JavaScriptCore/JavaScriptCore.h>

static NSString *JSString(JSStringRef value) {
    size_t length = JSStringGetMaximumUTF8CStringSize(value);
    char *buffer = malloc(length);
    JSStringGetUTF8CString(value, buffer, length);
    NSString *result = [NSString stringWithUTF8String:buffer] ?: @"";
    free(buffer);
    return result;
}

static PyObject *evaluateJS(PyObject *self, PyObject *args) {
    const char *source;
    if (!PyArg_ParseTuple(args, "s", &source)) return NULL;
    JSGlobalContextRef context = JSGlobalContextCreate(NULL);
    NSString *program = [@"var __riff_output=''; var console={log:function(x){__riff_output=String(x)}};\n" stringByAppendingString:[NSString stringWithUTF8String:source]];
    JSStringRef script = JSStringCreateWithUTF8CString(program.UTF8String);
    JSValueRef exception = NULL;
    JSEvaluateScript(context, script, NULL, NULL, 1, &exception);
    JSStringRelease(script);
    if (exception) {
        JSStringRef message = JSValueToStringCopy(context, exception, NULL);
        NSString *error = JSString(message);
        JSStringRelease(message);
        JSGlobalContextRelease(context);
        PyErr_SetString(PyExc_RuntimeError, error.UTF8String);
        return NULL;
    }
    JSStringRef outputScript = JSStringCreateWithUTF8CString("__riff_output");
    JSValueRef value = JSEvaluateScript(context, outputScript, NULL, NULL, 1, NULL);
    JSStringRef output = JSValueToStringCopy(context, value, NULL);
    NSString *result = JSString(output);
    PyObject *response = PyUnicode_FromString(result.UTF8String);
    JSStringRelease(output);
    JSStringRelease(outputScript);
    JSGlobalContextRelease(context);
    return response;
}

static PyMethodDef methods[] = {{"evaluate_js", evaluateJS, METH_VARARGS, "Evaluate a challenge with system JavaScriptCore."}, {NULL, NULL, 0, NULL}};
static struct PyModuleDef nativeModule = {PyModuleDef_HEAD_INIT, "riff_native", NULL, -1, methods};
PyMODINIT_FUNC PyInit_riff_native(void) { return PyModule_Create(&nativeModule); }

static NSString *errorJSON(NSString *message) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"error": message} options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

NSString *RiffPythonRequest(NSString *bundlePath, NSString *request) {
    @autoreleasepool {
        if (!Py_IsInitialized()) {
            PyImport_AppendInittab("riff_native", PyInit_riff_native);
            PyPreConfig preconfig;
            PyPreConfig_InitIsolatedConfig(&preconfig);
            preconfig.utf8_mode = 1;
            PyStatus status = Py_PreInitialize(&preconfig);
            if (PyStatus_Exception(status)) return errorJSON(@"Could not configure the embedded interpreter.");
            PyConfig config;
            PyConfig_InitIsolatedConfig(&config);
            config.write_bytecode = 0;
            config.install_signal_handlers = 0;
            config.buffered_stdio = 0;
            NSString *home = [bundlePath stringByAppendingPathComponent:@"python"];
            PyConfig_SetBytesString(&config, &config.home, home.UTF8String);
            config.module_search_paths_set = 1;
            NSArray<NSString *> *paths = @[@"python/lib/python3.13", @"python/lib/python3.13/lib-dynload", @"app", @"app_packages"];
            for (NSString *relative in paths) {
                wchar_t *path = Py_DecodeLocale([bundlePath stringByAppendingPathComponent:relative].UTF8String, NULL);
                PyWideStringList_Append(&config.module_search_paths, path);
                PyMem_RawFree(path);
            }
            status = Py_InitializeFromConfig(&config);
            PyConfig_Clear(&config);
            if (PyStatus_Exception(status)) return errorJSON(@"Could not initialize the embedded interpreter.");
            PyEval_SaveThread();
        }
        PyGILState_STATE state = PyGILState_Ensure();
        PyObject *module = PyImport_ImportModule("riff_backend");
        PyObject *function = module ? PyObject_GetAttrString(module, "dispatch_json") : NULL;
        PyObject *result = function ? PyObject_CallFunction(function, "s", request.UTF8String) : NULL;
        NSString *response;
        if (result) {
            const char *text = PyUnicode_AsUTF8(result);
            response = text ? [NSString stringWithUTF8String:text] : errorJSON(@"Invalid extractor response.");
        } else {
            PyObject *type = NULL, *value = NULL, *traceback = NULL;
            PyErr_Fetch(&type, &value, &traceback);
            PyErr_NormalizeException(&type, &value, &traceback);
            PyObject *description = value ? PyObject_Str(value) : NULL;
            const char *text = description ? PyUnicode_AsUTF8(description) : NULL;
            response = errorJSON(text ? [NSString stringWithUTF8String:text] : @"Media extraction failed.");
            Py_XDECREF(description); Py_XDECREF(type); Py_XDECREF(value); Py_XDECREF(traceback);
        }
        Py_XDECREF(result); Py_XDECREF(function); Py_XDECREF(module);
        PyGILState_Release(state);
        return response;
    }
}

#include <zlib.h>
#include <CommonCrypto/CommonKeyDerivation.h>

NSData *RiffArchiveTransform(NSData *input, BOOL decompress) {
    const NSUInteger limit = 16 * 1024 * 1024;
    if (input.length > (decompress ? limit + 1024 * 1024 : limit)) return nil;
    NSUInteger capacity = decompress ? limit : compressBound((uLong)input.length) + 64;
    NSMutableData *output = [NSMutableData dataWithLength:capacity];
    z_stream stream = {0};
    stream.next_in = (Bytef *)input.bytes;
    stream.avail_in = (uInt)input.length;
    stream.next_out = output.mutableBytes;
    stream.avail_out = (uInt)capacity;
    int result = decompress ? inflateInit2(&stream, -MAX_WBITS) : deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY);
    if (result != Z_OK) return nil;
    result = decompress ? inflate(&stream, Z_FINISH) : deflate(&stream, Z_FINISH);
    BOOL valid = result == Z_STREAM_END && stream.total_in == input.length;
    NSUInteger count = stream.total_out;
    if (decompress) inflateEnd(&stream); else deflateEnd(&stream);
    return valid ? [NSData dataWithBytes:output.bytes length:count] : nil;
}

NSData *RiffBackupKey(NSData *password, NSData *salt, uint32_t rounds) {
    if (!rounds || salt.length < 1 || password.length > 1024 * 1024 || salt.length > 1024) return nil;
    NSMutableData *key = [NSMutableData dataWithLength:32];
    int result = CCKeyDerivationPBKDF(kCCPBKDF2, password.bytes, password.length,
                                     salt.bytes, salt.length, kCCPRFHmacAlgSHA256, rounds, key.mutableBytes, key.length);
    return result == kCCSuccess ? key : nil;
}
