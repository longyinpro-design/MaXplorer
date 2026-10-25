import ctypes,json
lib=ctypes.CDLL('/usr/lib/libSystem.B.dylib')
port=ctypes.c_uint.in_dll(lib,'bootstrap_port').value
lib.bootstrap_look_up.argtypes=[ctypes.c_uint,ctypes.c_char_p,ctypes.POINTER(ctypes.c_uint)]
lib.bootstrap_strerror.argtypes=[ctypes.c_int]
lib.bootstrap_strerror.restype=ctypes.c_char_p
# Current macOS SDK servers/bootstrap.h: UNKNOWN_SERVICE is 1102.
BOOTSTRAP_NOT_PRIVILEGED=1100
result={}
for name in ['com.apple.windowserver.active','com.apple.ensemble.dragserver','com.apple.windowmanager.dragserver']:
    service=ctypes.c_uint()
    code=lib.bootstrap_look_up(port,name.encode(),ctypes.byref(service))
    reason=lib.bootstrap_strerror(code).decode()
    result[name]={'code':code,'reason':reason}
    if code!=BOOTSTRAP_NOT_PRIVILEGED:
        raise SystemExit('FAIL expected permission denial for '+name+': '+str(code)+' '+reason)
print(json.dumps({'desktop_services_denied':result}))
