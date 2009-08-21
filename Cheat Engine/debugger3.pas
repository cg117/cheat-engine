unit debugger3;
//third generation kernelmode debugger

interface

uses windows,sysutils,SyncObjs, dialogs,classes,debugger,disassembler,newkernelhandler,foundcodeunit,
     tlhelp32,cefuncproc;

type Tdebugevent =record
  EAX,EBX,ECX,EDX,ESI,EDI,EBP,ESP,EIP:DWORD;
end;

type
  TThreadListItem=record
    threadid: dword;
    threadhandle: dword;
  end;
  PThreadListItem=^TThreadListItem;


  TKDebugger=class;
  TDebuggerThread3=class(TThread)
  private
    addressfound: dword;
    currentDebugEvent: TDebugEvent;
    //debugregs: _context;
    threadlistCS: TCriticalSection;
    threadlist: array of dword;

    //breakpoints: array [0..3] of dword;
    //breakpointchanges: array [0..3] of tregistermodificationBP;
    
    owner: TKDebugger;    
    procedure foundone;
  public
    active: boolean;

    procedure execute; override;
    constructor create(owner: TKDebugger; suspended:boolean);
//    destructor destroy;  override;
  end;

  TKDebugger=class
  private
    DebuggerThread: TDebuggerThread3;

    breakpointCS: TCriticalSection;
    breakpoint: array [0..3] of record
      active: boolean;
      Address: DWORD;
      BreakType: TBreakType;
      BreakLength: TBreakLength;
    end;

    generaldebugregistercontext: TContext;
    fGlobalDebug: boolean;
    procedure setGlobalDebug(x: boolean);
  public
    procedure AddThread(ThreadID: Dword);
    procedure ApplyDebugRegistersForThread(threadhandle: DWORD);
    procedure ApplyDebugRegisters;    
    procedure StartDebugger;
    procedure StopDebugger;
    procedure SetBreakpoint(address: dword; BreakType: TBreakType; BreakLength: integer); overload;
    procedure SetBreakpoint(address: dword; BreakType: TBreakType; BreakLength: TBreakLength); overload;
    function isActive: boolean;
    property GlobalDebug: boolean read fGlobalDebug write setGlobalDebug;
    constructor create;
  end;
  

//var DebuggerThread3: TDebuggerThread3;

var KDebugger: TKDebugger;

implementation

uses frmProcessWatcherUnit,memorybrowserformunit;

Procedure TKDebugger.StartDebugger;
begin

  if processid=0 then raise exception.Create('Please open a process first');
  Debuggerthread:=TDebuggerThread3.create(self,false);
end;

Procedure TKDebugger.StopDebugger;
begin
  if (DebuggerThread<>nil) then
  begin
    Debuggerthread.Terminate;
    Debuggerthread.WaitFor;
    FreeAndNil(Debuggerthread);
  end;
end;

procedure TKDebugger.SetBreakpoint(address: dword; BreakType: TBreakType; BreakLength: integer);
//split up into seperate SetBreakpoint calls
var atleastone: boolean;
begin
  atleastone:=false;
  try
    while (breaklength>0) do
    begin
      if (breaklength=1) or (address mod 2 > 0) then
      begin
        atleastone:=true;
        SetBreakpoint(address, BreakType, bl_1byte);
        inc(address,1);
        dec(BreakLength,1);
      end;

      if (breaklength=2) or (address mod 4 > 0) then
      begin
        atleastone:=true;
        SetBreakpoint(address, BreakType, bl_2byte);
        inc(address,2);
        dec(BreakLength,2);
      end;

      if (breaklength=4) then
      begin
        atleastone:=true;
        SetBreakpoint(address, BreakType, bl_4byte);
        inc(address,4);
        dec(breaklength,4);
      end;
    end;
  except
    on e:Exception do
      if not atleastone then
        raise e;
  end;

end;

procedure TKDebugger.SetBreakpoint(address: dword; BreakType: TBreakType; BreakLength: TBreakLength);
//only call this from the main thread
var debugreg: integer;
    i: integer;
begin
  //find a debugreg spot not used yet

  debugreg:=-1;

  breakpointCS.Enter;
  for i:=0 to 3 do
    if not breakpoint[i].active then
    begin
      breakpoint[i].Address:=address;
      breakpoint[i].BreakType:=BreakType;
      breakpoint[i].BreakLength:=BreakLength;
      breakpoint[i].active:=true;

      debugreg:=i;
      break;
    end;
  breakpointCS.Leave;


  if debugreg=-1 then
    raise exception.Create('Out of debug registers');

  //apply the breakpoint
  if fGlobalDebug then
  begin
    //don't set the debugregs manually, let the taskswitching do the work for us
    //(for global debug the debugreg is just a recommendation, so don't watch for a dr6 result with this exit)
    DBKDebug_GD_SetBreakpoint(true,debugreg,address,breaktype,breaklength);
  end
  else
  begin
    //manually set the breakpoints in the global debug register context

    generaldebugregistercontext.Dr7:=generaldebugregistercontext.Dr7 and (not ((1 shl debugreg) or (3 shl 16+debugreg*2))) or (integer(breaktype) shl debugreg) or (integeR(breaklength) shl 16+debugreg*2);
    OutputDebugString(pchar(format('Setting DR7 to %x',[generaldebugregistercontext.Dr7])));

    case debugreg of
      0: generaldebugregistercontext.Dr0:=address;
      1: generaldebugregistercontext.Dr1:=address;
      2: generaldebugregistercontext.Dr2:=address;
      3: generaldebugregistercontext.Dr3:=address;
    end;

    //and apply
    ApplyDebugRegisters;
  end;
end;

procedure TKDebugger.AddThread(ThreadID: Dword);
var Threadhandle: thandle;
begin
  if not GlobalDebug then
  begin
    Debuggerthread.threadlistCS.Enter;
    try
      setlength(Debuggerthread.threadlist,length(Debuggerthread.threadlist)+1);
      threadhandle:=Openthread(STANDARD_RIGHTS_REQUIRED or windows.synchronize or $3ff,true,ThreadID);
      Debuggerthread.threadlist[length(Debuggerthread.threadlist)-1]:=threadhandle;
      ApplyDebugRegistersForThread(threadhandle);
    finally
      Debuggerthread.threadlistCS.Leave;
    end;
  end;
end;

procedure TKDebugger.ApplyDebugRegistersForThread(threadhandle: DWORD);
begin
  if not globaldebug then
  begin
    Debuggerthread.threadlistCS.Enter;
    try
      setthreadcontext(threadhandle, generaldebugregistercontext);
    finally
      Debuggerthread.threadlistCS.Leave;
    end;
  end;
end;

procedure TKDebugger.ApplyDebugRegisters;
var i: integer;
begin
  if not globaldebug then
  begin
    Debuggerthread.threadlistCS.Enter;
    try
      for i:=0 to length(Debuggerthread.threadlist)-1 do
        ApplyDebugRegistersForThread(Debuggerthread.threadlist[i]);
    finally
      Debuggerthread.threadlistCS.Leave;
    end;
  end;
end;

procedure TKDebugger.setGlobalDebug(x: boolean);
begin
  fGlobalDebug:=x;
  DBKDebug_SetGlobalDebugState(x);
end;

function TKDebugger.isActive: boolean;
begin
  result:=DebuggerThread <> nil;
end;

constructor TKDebugger.create;
begin
  breakpointCS:=TCriticalSection.Create;
  generaldebugregistercontext.ContextFlags:=CONTEXT_DEBUG_REGISTERS;
end;

//---------------------------------------

constructor TDebuggerThread3.create(owner: TKDebugger; suspended:boolean);
var ths: thandle;
    tE: threadentry32;
    i,j: integer;
    found: boolean;
    temp: thandle;
begin
  active:=true;
  self.owner:=owner;

  threadlistCS:=TCriticalSection.Create;
  inherited create(true);


  if not owner.GlobalDebug then
  begin

    //try to find this process in the processwatch window.
    found:=false;
    for i:=0 to length(frmprocesswatcher.processes)-1 do
    begin
      if frmprocesswatcher.processes[i].processid=processid then
      begin
        //open the threads
        for j:=0 to length(frmprocesswatcher.processes[i].threadlist)-1 do
        begin

          temp:=Openthread(STANDARD_RIGHTS_REQUIRED or windows.synchronize or $3ff,true,frmprocesswatcher.processes[i].threadlist[j].threadid);
          if temp<>0 then
          begin        
            setlength(threadlist,length(threadlist)+1);
            threadlist[length(threadlist)-1]:=temp;
          end;
        end;

        found:=true;
        break;

      end;
    end;

    if not found then
    begin
      //if it wasn't found try to add it (and tell the user it's best to start the process after ce has started)
      ths:=CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD,processid);
      try
        if ths<>0 then
        begin
          te.dwSize:=sizeof(te);
          if Thread32First(ths,te) then
          begin
            repeat
              if te.th32OwnerProcessID=processid then
              begin
                setlength(threadlist,length(threadlist)+1);
                threadlist[length(threadlist)-1]:=Openthread(STANDARD_RIGHTS_REQUIRED or windows.synchronize or $3ff,true,te.th32ThreadID);
              end;
            until not thread32Next(ths,te);
          end;
        end;
      finally
        closehandle(ths);
      end;
    end;
  end;

  if not suspended then resume;
end;



procedure TDebuggerThread3.foundone;
var desc,opcode: string;
    address: dword;
begin
{
  with foundcodedialog do
  begin
    address:=addressfound;
    opcode:=disassemble(address,desc);

    setlength(coderecords,length(coderecords)+1);
    coderecords[length(coderecords)-1].address:=addressfound;
    coderecords[length(coderecords)-1].size:=address-addressfound;
    coderecords[length(coderecords)-1].opcode:=opcode;
    coderecords[length(coderecords)-1].desciption:=desc;

    coderecords[length(coderecords)-1].eax:=currentdebugevent.EAX;
    coderecords[length(coderecords)-1].ebx:=currentdebugevent.EBX;
    coderecords[length(coderecords)-1].ecx:=currentdebugevent.ECX;
    coderecords[length(coderecords)-1].edx:=currentdebugevent.EDX;
    coderecords[length(coderecords)-1].esi:=currentdebugevent.Esi;
    coderecords[length(coderecords)-1].edi:=currentdebugevent.Edi;
    coderecords[length(coderecords)-1].ebp:=currentdebugevent.Ebp;
    coderecords[length(coderecords)-1].esp:=currentdebugevent.Esp;
    coderecords[length(coderecords)-1].eip:=currentdebugevent.Eip;
    Foundcodelist.Items.Add(opcode);
  end;
  }
end;

procedure TDebuggerThread3.execute;
var DebugEvent:array [0..49] of TDebugEvent;
    i,j,events: integer;
    offset: dword;
    opcode,desc: string;
    notinlist: boolean;
begin
  active:=true;
  try
    DBKDebug_StartDebugging(ProcessID);
    while not terminated do
    begin
      if DBKDebug_WaitForDebugEvent(1000) then
      begin
        OutputDebugString('KDebug event');


        DBKDebug_ContinueDebugEvent(false);
      end;

    {
      if foundcodedialog=nil then
      begin
        sleep(1000);
        continue;
      end;

      crdebugging.Enter;
      try
        //poll the debugevents
        events:=RetrieveDebugData(@DebugEvent);
        for i:=0 to events-1 do
        begin
          currentdebugevent:=DebugEvent[i];
          addressfound:=debugevent[i].EIP;
          offset:=addressfound;
          opcode:=disassemble(offset,desc);

          if pos('REP',opcode)=0 then
            addressfound:=previousopcode(addressfound)
          else
            if debugevent[i].Ecx=0 then addressfound:=previousopcode(addressfound);

          //check if the address is in the list
          notinlist:=true;
          try
            for j:=0 to length(foundcodedialog.coderecords)-1 do
              if foundcodedialog.coderecords[j].address=addressfound then //if it is in the list then set notinlist to false and go out of the loop
              begin
                notinlist:=false;
                break;
              end;
          except
            //list got shortened or invalid (or whatever weird bug)
          end;

          if notinlist then synchronize(foundone); //add this memory address to the foundcode window.
        end;


      finally
        crdebugging.Leave;
      end;
      sleep(250);
      //check for new threads and set their debug registers
      }
    end;

  except

  end;

  crdebugging.Enter;
{
  //disable the debugregs
  zeromemory(@debugregs,sizeof(debugregs));
  debugregs.ContextFlags:=CONTEXT_DEBUG_REGISTERS;
  debugregs.Dr7:=reg0set or reg1set or reg2set or reg3set;
  for i:=0 to length(threadlist)-1 do
  begin
    suspendthread(threadlist[i]);
    SetThreadContext(threadlist[i],Debugregs);
    resumethread(threadlist[i]);
  end;
         }
  //tell the kerneldriver to whipe out the debuggeerdprocesslist
  DBKDebug_Stopdebugging;
  
  crdebugging.Leave;
  active:=false;
end;

initialization
  KDebugger:=TKDebugger.create;


end.
