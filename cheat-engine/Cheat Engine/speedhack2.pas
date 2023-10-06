unit speedhack2;

{$MODE Delphi}

interface

uses Classes,LCLIntf, SysUtils, NewKernelHandler,CEFuncProc, symbolhandler, symbolhandlerstructs,  lua, lauxlib, lualib,
     autoassembler, dialogs,Clipbrd, commonTypeDefs, controls{$ifdef darwin},macport, FileUtil{$endif};

type
  TSpeedHackSetSpeedEvent=function(speed: single; out r: boolean; out error: string): boolean of object;
  TSpeedHackActivateEvent=function(out r: boolean; out error: string): boolean of object;


  TSpeedhack=class
  private
    fProcessId: dword;
    initaddress: ptrUint;
    lastSpeed: single;
  public
    procedure setSpeed(speed: single);
    function getSpeed: single;
    property processid: dword read fProcessId;
    constructor create;
    destructor destroy; override;
  end;

var speedhack: TSpeedhack;

function registerSpeedhackCallbacks(OnActivate: TSpeedHackActivateEvent; OnSetSpeed: TSpeedHackSetSpeedEvent): integer;
procedure unregisterSpeedhackCallbacks(id: integer);

implementation

uses frmAutoInjectUnit, networkInterface, networkInterfaceApi, ProcessHandlerUnit,
     Globals, luahandler, luacaller;

resourcestring
  rsFailureEnablingSpeedhackDLLInjectionFailed = 'Failure enabling speedhack. (DLL injection failed)';
  rsFailureConfiguringSpeedhackPart = 'Failure configuring speedhack part';
  rsFailureSettingSpeed = 'Failure setting speed';

type
  TSpeedhackCallback=record
    OnActivate: TSpeedHackActivateEvent;
    OnSetSpeed: TSpeedHackSetSpeedEvent;
  end;

var
  speedhackCallbacks: array of TSpeedhackCallback;


function registerSpeedhackCallbacks(OnActivate: TSpeedHackActivateEvent; OnSetSpeed: TSpeedHackSetSpeedEvent): integer;
var i: integer;
begin
  for i:=0 to length(speedhackCallbacks)-1 do
  begin
    if not (assigned(speedhackCallbacks[i].OnActivate) or assigned(speedhackCallbacks[i].OnSetSpeed)) then
    begin
      speedhackCallbacks[i].OnActivate:=OnActivate;
      speedhackCallbacks[i].OnSetSpeed:=OnSetSpeed;
      exit(i);
    end;
  end;

  result:=length(speedhackCallbacks);
  setlength(speedhackCallbacks, result+1);

  speedhackCallbacks[result].OnActivate:=OnActivate;
  speedhackCallbacks[result].OnSetSpeed:=OnSetSpeed;
end;

procedure unregisterSpeedhackCallbacks(id: integer);
begin
  if id<length(speedhackCallbacks) then
  begin
    CleanupLuaCall(TMethod(speedhackCallbacks[id].OnActivate));
    CleanupLuaCall(TMethod(speedhackCallbacks[id].OnSetSpeed));
    speedhackCallbacks[id].OnActivate:=nil;
    speedhackCallbacks[id].OnSetSpeed:=nil;
  end;
end;



constructor TSpeedhack.create;
var i: integer;
    script: tstringlist;

    disableinfo: TDisableInfo;
    x: ptrUint;
//      y: dword;
    a,b: ptrUint;
    c: TCEConnection;
    e: boolean;

    fname: string;
    err: boolean;

    path: string;

    QPCAddress: ptruint;
    mi: TModuleInfo;
    mat: qword;
    machmodulebase: qword;
    machmodulesize: qword;

    HookMachAbsoluteTime: boolean;

    nokernelbase: boolean=false;
    NoGetTickCount: boolean=false;
    NoQPC: boolean=false;
    NoGetTickCount64: boolean=false;

    r: boolean;
    error: string;

begin
  for i:=0 to length(speedhackCallbacks)-1 do
  begin
    if assigned(speedhackCallbacks[i].OnActivate) then
    begin
      if speedhackCallbacks[i].OnActivate(r,error) then
      begin
        //it got handled
        if r=false then
          raise exception.create(error);

        fprocessid:=processhandlerunit.processid;
        exit;
      end;
    end;
  end;

  initaddress:=0;

  if processhandler.isNetwork then
  begin
    c:=getconnection;
    c.loadExtension(processhandle); //just to be sure

    symhandler.reinitialize;
    symhandler.waitforsymbolsloaded(true);
  end
  else
  begin
    try
      {$ifdef darwin}
      if not FileExists('/usr/local/lib/libspeedhack.dylib') then
      begin
        ForceDirectories('/usr/local/lib/');

        path:=cheatenginedir+'libspeedhack.dylib';
        if CopyFile(path, '/usr/local/lib/libspeedhack.dylib', true)=false then
        begin
          raise exception.create('Failure copying libspeedhack.dylib to /usr/local/lib');
        end;
      end;

      if symhandler.getmodulebyname('libspeedhack.dylib', mi)=false then
      begin
        injectdll('/usr/local/lib/libspeedhack.dylib','');
        symhandler.reinitialize;
      end;

      {$endif}

      {$ifdef windows}
      if processhandler.is64bit then
        fname:='speedhack-x86_64.dll'
      else
        fname:='speedhack-i386.dll';

      symhandler.waitforsymbolsloaded(true, 'kernel32.dll'); //speed it up (else it'll wait inside the symbol lookup of injectdll)

      OutputDebugString('Speedhack: calling waitForExports');
      symhandler.waitForExports;
      OutputDebugString('Speedhack: waitForExports returned');
      symhandler.getAddressFromName('speedhackversion_GetTickCount',false,e);
      if e then
      begin
        OutputDebugString('Speedhack: speedhackversion_GetTickCount not found. Injecting DLL');
        injectdll(CheatEngineDir+fname);

        OutputDebugString('Speedhack: after dll injection. Waiting for symbols reinitialized');
        symhandler.reinitialize;
        symhandler.waitforsymbolsloaded(true);
        OutputDebugString('Speedhack: after waitforsymbolsloaded. Calling symhandler.waitForExports');
        symhandler.waitForExports;
      end;
      {$endif}



    except
      on e: exception do
      begin
        raise exception.Create(rsFailureEnablingSpeedhackDLLInjectionFailed+': '+e.message);
      end;
    end;
  end;


  script:=tstringlist.Create;
  try
    if processhandler.isNetwork then
    begin
      OutputDebugString('Speedhack: networked');
      //linux


      //gettimeofday

      if symhandler.getAddressFromName('vdso.gettimeofday', true, err)>0 then //prefered
        fname:='vdso.gettimeofday'
      else
      if symhandler.getAddressFromName('libc.gettimeofday', true, err)>0 then //secondary
        fname:='libc.gettimeofday'
      else
      if symhandler.getAddressFromName('gettimeofday', true, err)>0 then //really nothing else ?
        fname:='gettimeofday'
      else
        fname:=''; //give up


      if fname<>'' then //hook gettimeofday
      begin
        //check if it already has a a speedhack running
        a:=symhandler.getAddressFromName('real_gettimeofday');
        b:=0;

        readprocessmemory(processhandle,pointer(a),@b,processhandler.pointersize,x);
        if b=0 then //not yet hooked
        begin
          generateAPIHookScript(script, fname, 'new_gettimeofday', 'real_gettimeofday');

          try
            //Clipboard.AsText:=script.text;
            autoassemble(script,false);
          except
          end;
        end;
      end;

      script.clear;
      //clock_gettime
      if symhandler.getAddressFromName('vdso.clock_gettime', true,err)>0 then //prefered
        fname:='vdso.clock_gettime'
      else
      if symhandler.getAddressFromName('libc.clock_gettime', true, err)>0 then //seen this on android
        fname:='libc.clock_gettime'
      else
      if symhandler.getAddressFromName('librt.clock_gettime', true, err)>0 then //secondary
        fname:='librt.clock_gettime'
      else
      if symhandler.getAddressFromName('clock_gettime', true, err)>0 then //really nothing else ?
        fname:='clock_gettime'
      else
        fname:=''; //give up


      if fname<>'' then //hook clock_gettime
      begin
        //check if it already has a a speedhack running
        a:=symhandler.getAddressFromName('real_clock_gettime');
        b:=0;

        readprocessmemory(processhandle,pointer(a),@b,processhandler.pointersize,x);
        if b=0 then //not yet hooked
        begin
          generateAPIHookScript(script, fname, 'new_clock_gettime', 'real_clock_gettime');

          try
           // Clipboard.AsText:=script.text;
            autoassemble(script,false);
          except
          end;
        end;
      end;

    end
    else
    begin
      //local
      OutputDebugString('Speedhack: local');

      {$ifdef darwin}
      OutputDebugString('Speedhack: mac');
      HookMachAbsoluteTime:=false;
      if speedhack_HookMachAbsoluteTime then
      begin

        mat:=symhandler.getAddressFromName('mach_absolute_time', false, err);
        if symhandler.getmodulebyaddress(mat,mi) then
        begin
          machmodulebase:=mi.baseaddress;
          machmodulesize:=mi.basesize;


          if processhandler.is64Bit then
          begin
            script.add('machmodulebase:');
            script.add('dq '+inttohex(machmodulebase,8));

            script.Add('machmodulesize:');
            script.Add('dq '+inttohex(machmodulesize,8));
          end
          else
          begin
            script.add('machmodulebase:');
            script.add('dd '+inttohex(machmodulebase,8));

            script.add('machmodulesize:');
            script.add('dd '+inttohex(machmodulesize,8));
          end;

          HookMachAbsoluteTime:=true;
        end;
        //  raise exception.create('mach_absolute_time not found');

      end;


      a:=symhandler.getAddressFromName('realGetTimeOfDay') ;
      b:=0;
      readprocessmemory(processhandle,pointer(a),@b,processhandler.pointersize,x);
      if b<>0 then //already configured
      begin
        generateAPIHookScript(script, 'gettimeofday', 'speedhackversion_GetTimeOfDay','','1');
        if HookMachAbsoluteTime then
          generateAPiHookScript(script, 'mach_absolute_time', 'speedhackversion_MachAbsoluteTime','','2');
      end
      else
      begin
        generateAPIHookScript(script, 'gettimeofday', 'speedhackversion_GetTimeOfDay', 'realGetTimeOfDay','1');
        if HookMachAbsoluteTime then
          generateAPiHookScript(script, 'mach_absolute_time', 'speedhackversion_MachAbsoluteTime','realMachAbsoluteTime','2');
      end;

      {$endif}

      {$ifdef windows}
      OutputDebugString('Speedhack: windows');
      noKernelBase:=false; //assume it present


      //check if it already has a a speedhack script running

      fname:='kernelbase.GetTickCount';
      a:=symhandler.getAddressFromName(fname, true,e);
      if e then
      begin
        noKernelBase:=true;
        OutputDebugString('No kernelbase.GetTickCount');

        fname:='kernel32.GetTickCount';
        a:=symhandler.getAddressFromName(fname, true,e);

        if e then
        begin
          outputdebugstring('No kernel32.GetTickCount');
          fname:='GetTickCount';
          a:=symhandler.getAddressFromName(fname, true,e);

          if e then
          begin
            NoGetTickCount:=true;
            outputdebugstring('No GetTickCount');
          end;
        end;
      end;

      if processhandler.is64bit then
        script.Add('alloc(init,512,'+fname+')')
      else
        script.Add('alloc(init,512)');

      if NoGetTickCount=false then
      begin
        OutputDebugString('Speedhack: hooking '+fname);
        a:=symhandler.getAddressFromName('realgettickcount', true) ;
        b:=0;
        readprocessmemory(processhandle,pointer(a),@b,processhandler.pointersize,x);
        if b<>0 then //already configured
          generateAPIHookScript(script, fname, 'speedhackversion_GetTickCount')
        else
          generateAPIHookScript(script, fname, 'speedhackversion_GetTickCount', 'realgettickcount');
      end;
      {$endif}

      try
        disableinfo:=TDisableInfo.create;
        try
          OutputDebugString('Speedhack: init1');
          if autoassemble(script,false,true,false,false,disableinfo)=false then
            OutputDebugString('Speedhack: Error assembling speedhack init 1');
          //clipboard.AsText:=script.text;

          //fill in the address for the init region
          for i:=0 to length(disableinfo.allocs)-1 do
            if disableinfo.allocs[i].varname='init' then
            begin
              initaddress:=disableinfo.allocs[i].address;
              break;
            end;
        finally
          disableinfo.free;
        end;


      except
        on e:exception do
        begin
          clipboard.AsText:=script.text;
          raise exception.Create(rsFailureConfiguringSpeedhackPart+' 1: '+e.message);
        end;
      end;
      {$ifdef windows}

      if (NoGetTickCount=false) and (nokernelbase=false) then //hook kernel32.GetTickCount as well
      begin
        if symhandler.getAddressFromName('kernel32.GetTickCount',true,err)>0 then
        begin
          OutputDebugString('Speedhack: hooking kernel32.GetTickCount');
          script.Clear;
          script.Add('kernel32.GetTickCount:');
          script.Add('jmp speedhackversion_GetTickCount');
          try
            autoassemble(script,false);
          except //don't mind
            on e: exception do
            begin
              OutputDebugString('Speedhack: Error hooking kernelbase.GetTickCount: '+e.message);
            end;
          end;
        end;
      end;

      //timegettime
      if symhandler.getAddressFromName('timeGetTime',true,err)>0 then //might not be loaded
      begin
        OutputDebugString('Speedhack: hooking timeGetTime');
        script.Clear;
        script.Add('timeGetTime:');
        script.Add('jmp speedhackversion_GetTickCount');
        try
          autoassemble(script,false);
        except //don't mind
          on e:exception do
          begin
            OutputDebugString('Speedhack: Error hooking timeGetTime: '+e.message);
          end;
        end;
      end;


      //qpc
      fname:='ntdll.RtlQueryPerformanceCounter';
      qpcaddress:=symhandler.getAddressFromName(fname,true, err);
      if err then
      begin
        fname:='kernel32.QueryPerformanceCounter';
        qpcaddress:=symhandler.getAddressFromName(fname,true, err);

        if err then
        begin
          fname:='';
          NoQPC:=true;
        end;
      end;


      if not noqpc then
      begin
        OutputDebugString('Speedhack: hooking '+fname);
        script.clear;
        a:=symhandler.getAddressFromName('realQueryPerformanceCounter') ;
        b:=0;
        readprocessmemory(processhandle,pointer(a),@b,processhandler.pointersize,x);

        if b<>0 then //already configured
          generateAPIHookScript(script, inttohex(qpcaddress,8), 'speedhackversion_QueryPerformanceCounter')
        else
          generateAPIHookScript(script, inttohex(qpcaddress,8), 'speedhackversion_QueryPerformanceCounter', 'realQueryPerformanceCounter');

        try
          autoassemble(script,false);
        except //do mind
          on e:exception do
          begin
            OutputDebugString('Speedhack: Error hooking '+fname+' : '+e.message);
            raise exception.Create(rsFailureConfiguringSpeedhackPart+' 2');
          end;
        end;
      end;

      //gettickcount64
      fname:='kernelbase.GetTickCount64';
      a:=symhandler.getAddressFromName(fname,true,err);
      if err then
      begin
        nokernelbase:=true;
        fname:='kernel32.GetTickCount64';
        a:=symhandler.getAddressFromName(fname,true,err);
        if err then
        begin
          fname:='GetTickCount64';
          a:=symhandler.getAddressFromName(fname,true,err);
          if err then
            NoGetTickCount64:=true;
        end;
      end;

      if not NoGetTickCount64 then
      begin
        script.clear;
        a:=symhandler.getAddressFromName('realGetTickCount64') ;
        b:=0;
        readprocessmemory(processhandle,pointer(a),@b,processhandler.pointersize,x);
        if b<>0 then //already configured
          generateAPIHookScript(script, fname, 'speedhackversion_GetTickCount64')
        else
          generateAPIHookScript(script, fname, 'speedhackversion_GetTickCount64', 'realGetTickCount64');

        try
          autoassemble(script,false);
        except //do mind
          on e:exception do
          begin
            OutputDebugString('Speedhack: Error hooking '+fname+' : '+e.message);
            raise exception.Create(rsFailureConfiguringSpeedhackPart+' 3');
          end;
        end;

        if not nokernelbase then
        begin
          if symhandler.getAddressFromName('kernel32.GetTickCount64',true,err)>0 then
          begin
            script.Clear;
            script.Add('kernel32.GetTickCount64:');
            script.Add('jmp speedhackversion_GetTickCount64');
            try
              autoassemble(script,false);
            except //don't mind
              on e:exception do
                OutputDebugString('Speedhack: Error hooking kernel32.GetTickCount64 : '+e.message);
            end;
          end;
        end;

      end;
      {$endif}


    end;

  finally
    script.free;
  end;

  setspeed(1);
  fprocessid:=processhandlerunit.processid;

end;

destructor TSpeedhack.destroy;
var script: tstringlist;
    i: integer;
    x: dword;
begin
  if fprocessid=processhandlerunit.ProcessID then
  begin
    try
      setSpeed(1);
    except
    end;
  end;

  //do not undo the speedhack script (not all games handle a counter that goes back)

  inherited destroy;
end;

function TSpeedhack.getSpeed: single;
begin
  if self=nil then
    result:=1
  else
    result:=lastspeed;
end;

procedure TSpeedhack.setSpeed(speed: single);
var
  x: single;
  script: Tstringlist;
  i: integer;
  r: boolean;
  error: string;
begin
  for i:=0 to length(speedhackCallbacks)-1 do
  begin
    if assigned(speedhackCallbacks[i].OnSetSpeed) then
    begin
      if speedhackCallbacks[i].OnSetSpeed(speed,r,error) then
      begin
        if not r then raise exception.create(error);
        lastspeed:=speed;
        exit;
      end;
    end;
  end;

  if processhandler.isNetwork then
  begin
    getConnection.speedhack_setSpeed(processhandle, speed);
    lastspeed:=speed;
  end
  else
  begin
    x:=speed;
    script:=tstringlist.Create;
    try
      script.add('CreateThread('+inttohex(initaddress,8)+')');
      script.add('label(newspeed)');
      script.add(inttohex(initaddress,8)+':');
      if processhandler.is64Bit then
      begin
        script.add('sub rsp,#40');
        script.add('movss xmm0,[newspeed]');
      end
      else
        script.add('push [newspeed]');

      script.add('call InitializeSpeedhack');

      if processhandler.is64Bit then
      begin
        script.add('add rsp,#40');
        script.add('ret');
      end
      else
      begin
        script.add('ret 4');
      end;

      script.add('newspeed:');
      script.add('dd '+inttohex(pdword(@x)^,8));

      try
        autoassemble(script,false);
      except
        raise exception.Create(rsFailureSettingSpeed);
      end;

      lastspeed:=speed;
    finally
      script.free;
    end;

  end;

end;


end.
