"""JNI ownership and coroutine waiting checks; uses a local Lua 5.1/LuaJIT executable."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
LUA = os.environ.get('LUA') or shutil.which('luajit') or shutil.which('lua5.1') or shutil.which('lua')
MODULE = ROOT / 'files/assets/neomloader/lib/android/screenshot.lua'


def lua_string(value):
    return '"' + ''.join('\\%03d' % byte for byte in str(value).encode('utf-8')) + '"'


@unittest.skipUnless(LUA, 'Set LUA to a Lua 5.1 or LuaJIT executable')
class ScreenshotTests(unittest.TestCase):
    def run_lua(self, test):
        with tempfile.TemporaryDirectory(prefix='screenshot-jni-test-') as directory:
            prelude = 'local directory=' + lua_string(directory) + '\n'
            prelude += 'function getWorkingDirectory() return ' + lua_string(ROOT / 'files/assets/neomloader') + ' end\n'
            prelude += r'''local frames,globals,deleted,inits,captures,waits=0,0,0,0,0,0
local accepted,readonly=true,true
local statuses,index={2},0
local java_error,load_error='',false
local class={kind='local'}
local global={kind='global'}
local ffi={cast=function(_,value) return value end,gc=function(ref,fn) return ref end}
local env={
 PushLocalFrame=function() frames=frames+1; return 0 end,
 PopLocalFrame=function() frames=frames-1 end,
 NewGlobalRef=function(ref) assert(ref==class); globals=globals+1; return global end,
 DeleteGlobalRef=function(ref) assert(ref==global) end,
 DeleteLocalRef=function(ref) assert(ref~=global); deleted=deleted+1 end,
 FindClass_safe=function(name) return {name=name} end,
 NewStringUTF=function(value) return value end,
}
local envu={
 CallObjectMethod=function(object,name,signature,...)
  if name=='getCodeCacheDir' then return {} end
  if name=='getAbsolutePath' then return directory end
  if name=='getClassLoader' then return {} end
  if name=='loadClass' then
   assert((...)=='mtg.screenshot.ScreenshotBridge')
   if load_error then error('Java load error') end
   return class
  end
  error(name)
 end,
 FromJString=function(value) return value end,
 CallConstructor=function() return {} end,
 CallBooleanMethod=function(_,name) assert(name=='setReadOnly'); return readonly end,
 CallStaticVoidMethod=function(ref,name) assert(ref==class and name=='init'); inits=inits+1 end,
 CallStaticBooleanMethod=function(ref,name)
  assert(ref==global and frames==0 and name=='capture'); captures=captures+1; return accepted
 end,
 CallStaticIntMethod=function(ref,name)
  assert(ref==global and name=='getStatus'); index=index+1; return statuses[math.min(index,#statuses)]
 end,
 CallStaticObjectMethod=function(ref,name)
  assert(ref==global)
  if name=='getResult' then return 'content://media/1' end
  assert(name=='getError'); return java_error
 end,
}
package.preload['ffi']=function() return ffi end
package.preload['android.jni-raw']=function() return {activity={}} end
package.preload['android.jnienv']=function() return env end
package.preload['android.jnienv-util']=function() return envu end
function wait(ms) assert(ms==50); waits=waits+1 end
'''
            prelude += 'local screenshot=assert(loadfile(' + lua_string(MODULE) + '))()\n'
            result = subprocess.run([LUA, '-'], input=(prelude + test).encode('utf-8'), capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', errors='replace'))

    def test_boolean_and_numeric_results_and_cached_global_class(self):
        self.run_lua('''assert(screenshot.capture())
accepted=false; assert(not screenshot.capture())
accepted=0; assert(not screenshot.capture())
accepted=1; assert(screenshot.capture())
assert(captures==4 and inits==1 and globals==1 and frames==0)
assert(screenshot.result()=='content://media/1' and deleted==1)
''')

    def test_wait_for_success(self):
        self.run_lua('''statuses={1,1,2}
local ok,uri=screenshot.save()
assert(ok and uri=='content://media/1' and waits==2 and captures==1)
''')

    def test_busy_and_java_failure(self):
        self.run_lua('''accepted=false
local ok,reason=screenshot.save(); assert(not ok and reason~='' and waits==0)
accepted=true; statuses={1,3}; java_error='Permission error'
ok,reason=screenshot.save(); assert(not ok and reason==java_error and waits==1)
''')

    def test_stop_and_timeout_leave_java_save_alone(self):
        self.run_lua('''statuses={1}
local ok,reason=screenshot.save(function() return waits==1 end)
assert(not ok and reason==nil and waits==1 and captures==1)
waits=0; ok,reason=screenshot.save()
assert(not ok and reason~='' and waits==600 and captures==2)
''')

    def test_failed_load_pops_jni_frame_and_can_retry(self):
        self.run_lua('''load_error=true
local ok=screenshot.save(); assert(not ok and frames==0 and globals==0)
load_error=false; assert(screenshot.capture() and frames==0 and globals==1)
''')

    def test_readonly_is_required_before_loading(self):
        self.run_lua('''readonly=0
local ok=screenshot.save(); assert(not ok and inits==0 and frames==0)
readonly=1; assert(screenshot.capture() and inits==1)
''')

    def test_jni_poll_error_does_not_escape(self):
        self.run_lua('''envu.CallStaticIntMethod=function() error('JNI unavailable') end
local ok,reason=screenshot.save(); assert(not ok and reason~='' and waits==0)
''')


if __name__ == '__main__':
    unittest.main(verbosity=2)
