(*
 * Copyright 2021 Mirko Bianco (email: writetomirko@gmail.com)
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:

 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 *)

unit Fido.VirtualStatement;

interface

uses
  System.Rtti,
  System.TypInfo,
  System.Classes,
  Data.DB,

  Spring,
  Spring.Container,
  Spring.Collections,
  Spring.Collections.Base,

  Fido.Utilities,
  Fido.Exceptions,
  Fido.Db.TypeConverter,
  Fido.Resource.StringReader.Intf,
  Fido.Types,
  Fido.Virtual.Attributes,
  Fido.VirtualStatement.Attributes,
  Fido.StatementExecutor.Intf,
  Fido.VirtualInterface,
  Fido.ValueEnumerator.Intf,
  Fido.ValueEnumerator,
  Fido.VirtualStatement.Intf,
  Fido.VirtualStatement.Metadata.Intf;

type
  EFidoVirtualStatementError = class(EFidoException);

  TVirtualStatement<T: IVirtualStatement> = class(TVirtualInterface<T>, IVirtualStatementMetadata)
  strict private const
    GetterPrefix = 'GET';
    DatasetOperationNames: array [TDatasetOperation] of string = ('', 'NEXT', 'FIRST', 'CLOSE', 'GETEOF');
    resTemplateSequence = 'SQL_VIRTUAL_TEMPLATE_SEQUENCE';
    resTemplateFunction = 'SQL_VIRTUAL_TEMPLATE_FUNCTION';
  strict private
    FDescription: string;
    FStatementData: string;
    FStatementType: TStatementType;
    FResourcedSQL: string;
    FParameterCommaList: string;
    FExecutor: IStatementExecutor;
    FExecMethod: TMethodDescriptor;
    FDataset: TDataset;
    FEnumerator: Weak<IEnumerator>;
    FParams: IDictionary<string,TParamDescriptor>;
    FMethods: IDictionary<string, TMethodDescriptor>;

    function AddOrUpdateDescriptor(const OriginalName: string; const RttiType: TRttiType; const Direction: TParamType; const IsFunction: Boolean; const IsPagingLimit: Boolean;
      const IsPagingOffset: Boolean; const SqlInjectTag: string): TParamDescriptor;
    procedure ProcessAllAttributes;
    procedure CacheColumns;
  private
    function GetIsGetterName(const Name: string): boolean;
    function GetMappedName(const Name: string; const IsFunction: boolean): string;
    function ExtractSQLString(const ResString: string): string;
    function GetSQLData: string;
    function GetIsDefined: boolean;
    procedure SetEnumeratorValue(out Result: TValue);
    procedure DoInvoke(Method: TRttiMethod; const Args: TArray<TValue>; out Result: TValue);
    procedure Execute(const Method: TRttiMethod; const Args: TArray<TValue>; out Result: TValue);
    procedure ProcessAttribute(const Attribute : TCustomAttribute; const Method: TRttiMethod = nil; const MethDesc: TMethodDescriptor = nil);
    procedure ProcessMethod(const Method: TRttiMethod);
    procedure RaiseError(const Msg: string; const Args: array of const);
    procedure TestDatasetOpen(const MethodToBeCalled: string);
    procedure SetExecMethod(const Value: TMethodDescriptor);
    procedure DefineStatement(const Method: TRttiMethod; const Args: TArray<TValue>);
    procedure ValidateStatement;
    function ReplaceSqlInject(const Sql: string; const Args: TArray<TValue>): string;

    property Executor: IStatementExecutor read FExecutor;
    property ExecMethod: TMethodDescriptor read FExecMethod write SetExecMethod;
  public
    constructor Create(const ResReader: IStringResourceReader; const StatementExecutor: IStatementExecutor);

    class function GetInstance(const Container: TContainer; const StatementExecutorServiceName: string = ''): TVirtualStatement<T>; static;
    // IVirtualStatementMetadata
    function GetDescription: string;
    function GetIsScalar: boolean;
    function GetStatementType: TStatementType;
    function GetStatementData: string;

    property StatementType: TStatementType read GetStatementType;
    property StatementData: string read GetStatementData;
  end;

implementation

uses
  System.SysUtils,
  System.Variants,
  System.Generics.Collections;

{ TVirtualStatement<T> }

function TVirtualStatement<T>.AddOrUpdateDescriptor(
  const OriginalName: string;
  const RttiType: TRttiType;
  const Direction: TParamType;
  const IsFunction: Boolean;
  const IsPagingLimit: Boolean;
  const IsPagingOffset: Boolean;
  const SqlInjectTag: string): TParamDescriptor;
var
  MappedName: string;
begin
  MappedName := GetMappedName(OriginalName, IsFunction);

  if FParams.TryGetValue(MappedName, Result) then
  begin
    if (Direction = ptOutput) and (Result.Direction = ptInput) then
      Result.Direction := ptInputOutput;
    // these must not change
    Assert(Result.DataType = DataTypeConverter.GetDescriptor(RttiType));
    Exit;
  end
  else begin
    Result := TParamDescriptor.Create;
    FParams.Add(MappedName, Result);
    Result.Index := FParams.Count;
    Result.MappedName := MappedName;
    Result.DataType := DataTypeConverter.GetDescriptor(RttiType);
    Result.Direction := Direction;
    Result.IsPagingLimit := IsPagingLimit;
    Result.IsPagingOffset := IsPagingOffset;
    Result.SqlInjectTag := SqlInjectTag;
    if Direction in [ptInput, ptInputOutput] then
      FParameterCommaList := FParameterCommaList + ', :' + MappedName;
  end;
end;

procedure TVirtualStatement<T>.CacheColumns;
var
  D: TPair<string, TMethodDescriptor>;
  Field: TField;
begin
  FMethods.Values.ForEach(
    procedure(const Value: TMethodDescriptor)
    begin
      case Value.Category of
        mcColGetter:
        begin
          Field := FDataset.FieldByName(Value.MappedName);
          if Assigned(Field) then
            Value.FieldValue := Field.Value;
        end;
        mcExecute:
          if Value.IsFunction then
          begin
            // try to find field matching function name
            Field := FDataset.FindField(Value.MappedName);
            // if none use first
            if Assigned(Field) then
            begin
              Value.FieldValue := Field.Value;
            end
            else
            begin
              Field := FDataset.Fields[0];
              Value.FieldValue := Field.Value;
            end;
          end;
      end;
    end);
end;

constructor TVirtualStatement<T>.Create(
  const ResReader: IStringResourceReader;
  const StatementExecutor: IStatementExecutor);
var
  ResName: string;
begin
  Guard.CheckNotNull(ResReader, 'ResReader');
  inherited Create(DoInvoke);

  FExecutor := Utilities.CheckNotNullAndSet(StatementExecutor, 'StatementExecutor');
  FParams := TCollections.CreateDictionary<string, TParamDescriptor>([doOwnsValues]);
  FMethods := TCollections.CreateDictionary<string, TMethodDescriptor>([doOwnsValues]);

  ProcessAllAttributes;
  ValidateStatement;

  // obtain query definition to get SQL from resources
  case StatementType of
    stSequence:
      ResName := resTemplateSequence;
    stFunction:
      ResName := resTemplateFunction;
    else
      if StatementType in stResourced then
        ResName := StatementData
      else
        ResName := EmptyStr;
  end;
  if ResName <> EmptyStr then
    FResourcedSQL := ExtractSQLString(ResReader.GetStringResource(ResName));
end;

function TVirtualStatement<T>.ReplaceSqlInject(
  const Sql: string;
  const Args: TArray<TValue>): string;
var
  FixedSql: string;
begin
  FixedSql := Sql;

  FParams.Values.ForEach(
    procedure(const Descriptor: TParamDescriptor)
    begin
      if not Descriptor.SqlInjectTag.IsEmpty then
        FixedSql := FixedSql.Replace(Format('%%%s%%', [Descriptor.SqlInjectTag]), Descriptor.DataType.GetAsVariant(Args[Descriptor.Index]), [rfReplaceAll]);
    end);

  Result := FixedSql
end;

procedure TVirtualStatement<T>.DefineStatement(
  const Method: TRttiMethod;
  const Args: TArray<TValue>);
var
  ParamsList: IList<TParamDescriptor>;
  Param: TParamDescriptor;
  IsPagingLimit: Boolean;
  IsPagingOffset: Boolean;
  SqlInjectTag: string;
  MappedName: string;
begin
  Assert((StatementType in stValid) and not Executor.IsBuilt and Method.Name.Equals(ExecMethod.OriginalName));

  ParamsList := TCollections.CreateList<TParamDescriptor>;

  // prepare our list of paramters prior to defining them in executor
  // so we know their directions and are able to define parameter list
  if StatementType in stParametrised then
  begin
    FParameterCommaList := '';

    TCollections.CreateList<TRttiParameter>(Method.GetParameters).ForEach(
      procedure(const Arg: TRttiParameter)
      begin
        IsPagingLimit := False;
        IsPagingOffset := False;

        TCollections.CreateList<TCustomAttribute>(Arg.GetAttributes).ForEach(
          procedure(const Attribute: TCustomAttribute)
          begin
            if Attribute is PagingLimitAttribute then
              IsPagingLimit := True
            else if Attribute is PagingOffsetAttribute then
              IsPagingOffset := True
            else if Attribute is ColumnAttribute then
              MappedName := ColumnAttribute(Attribute).Line
            else if Attribute is SqlInjectAttribute then
              SqlInjectTag := (Attribute as SqlInjectAttribute).Tag;
          end);

        Param := AddOrUpdateDescriptor(Arg.Name, Arg.ParamType, ptInput, False, IsPagingLimit, IsPagingOffset, SqlInjectTag);
        if MappedName <> '' then
          Param.MappedName := MappedName;

        ParamsList.Add(Param);
      end);

    // define OUT ora update IN/OUT parameter in stored procedures
    if ExecMethod.IsFunction and (StatementType = stStoredProc) then
      ParamsList.Add(AddOrUpdateDescriptor(Method.Name, Method.ReturnType, ptOutput, True, False, False, ''));

    // TODO param values could also be set with setters

    // remove first ', ' from parameter list used by function definition
    Delete(FParameterCommaList, 1, 2);
  end;

  // tell Executor to construct object
  Executor.BuildObject(StatementType, ReplaceSqlInject(GetSQLData, Args));

  // define parameters in executor once Direction and ParameterList is finally established
  ParamsList
    .Where(function(const Item: TParamDescriptor): Boolean
      begin
        Result := not(Item.IsPagingLimit or Item.IsPagingOffset);
      end)
    .ForEach(procedure(const Item: TParamDescriptor)
      begin
        Executor.AddParameter(Item.MappedName, Item.DataType.FieldType, Item.Direction);
      end);

  Executor.Prepare;
end;

procedure TVirtualStatement<T>.DoInvoke(
  Method: TRttiMethod;
  const Args: TArray<TValue>;
  out Result: TValue);
var
  MethodDesc: TMethodDescriptor;
begin
  MethodDesc := FMethods.GetValueOrDefault(Method.Name);

  // all methods should be cached and processed by now
  Assert(Assigned(MethodDesc) and (MethodDesc.Category in [
    mcExecute, mcDatasetOper, mcColGetter, mcRowsAffected]));

  case MethodDesc.Category of
    mcExecute:
      Execute(Method, Args, Result);

    mcRowsAffected:
      Result := Executor.GetRowsAffected;

    mcColGetter, mcDatasetOper:
      begin
        TestDatasetOpen(Method.Name);

        if MethodDesc.Category = mcColGetter then
        begin
          Result := MethodDesc.Converter.GetFromVariant(MethodDesc.FieldValue);
        end
        else
        case MethodDesc.Operation of
          dsNext:
            FDataset.Next;
          dsFirst:
            FDataset.First;
          dsClose:
            FDataset.Close;
          dsEOF:
            Result := FDataset.Eof;
        end;
      end;
  end;
end;

procedure TVirtualStatement<T>.Execute(
  const Method: TRttiMethod;
  const Args: TArray<TValue>;
  out Result: TValue);
var
  PagingLimit: Integer;
  PagingOffset: Integer;
begin
  // define statement (assign SQL data, declare parameters) if necessary
  if not GetIsDefined then
    DefineStatement(Method, Args);

  PagingLimit := -1;
  PagingOffset := -1;

  FParams.Values.ForEach(
    procedure(const Descriptor: TParamDescriptor)
    begin
      if (Descriptor.Direction in [ptInput, ptInputOutput]) and
         not(Descriptor.IsPagingLimit or Descriptor.IsPagingOffset) then
        // convert value to variant (stripping Nullable to its base type if necessary)
        Executor.SetParameterValue(Descriptor.MappedName, Descriptor.DataType.GetAsVariant(Args[Descriptor.Index]))
      else if Descriptor.IsPagingLimit then
        PagingLimit := Args[Descriptor.Index].AsInteger
      else if Descriptor.IsPagingOffset then
        PagingOffset := Args[Descriptor.Index].AsInteger;
    end);

  if (PagingLimit <> 0) then
  begin
    Executor.SetPaging(PagingLimit, PagingOffset);
  end;

  // open dataset if query like
  if StatementType in stOpenable then
  begin
    FDataset := Executor.Open;
    // prepare column cache (as fields may be recreated on every Open)
    CacheColumns;
    // scalar calls can be closed immediately
    case ExecMethod.ReturnType of
      rtNone:
        ; // procedure, no result
      rtEnum:
        SetEnumeratorValue(Result);
      rtInteger, rtOther:
        begin
          Result := ExecMethod.Converter.GetFromVariant(ExecMethod.FieldValue);
          FDataset.Close;
        end;
      else
        ; // TODO raise unimplemented;
    end;
  end
  // or execute in case of commands and stored procedures
  else
  begin
    Assert(StatementType in stExecutable);
    FDataset := nil;
    Executor.Execute;
    // for commands we can return RowsAffected if requested
    if (StatementType = stCommand) and (ExecMethod.ReturnType = rtInteger) then
      Result := Executor.GetRowsAffected
    // for procedure we can return parameter matchin the Execute method name
    else if (StatementType = stStoredProc) and ExecMethod.IsFunction then
      Result := ExecMethod.Converter.GetFromVariant(
        Executor.GetParameterValue(ExecMethod.MappedName));
  end;
end;

function TVirtualStatement<T>.ExtractSQLString(const ResString: string): string;
const
  ControlBlockStart = '/*';
  ControlBlockEnd = '*/';
var
  PosDescEnd: integer;
begin
  // TODO extraction of SQL can be remove once all query resource have their
  // control blocks (with e.g. Destiption string) removed

  Result := ResString;

  if not SameText(ControlBlockStart, Copy(Result, 1, Length(ControlBlockStart))) then
    Exit;

  // split the whole text on the first end of comment
  PosDescEnd := Pos(ControlBlockEnd, Result);
  if PosDescEnd = -1 then
    raise EFidoException.CreateFmt('Malformed SQL control block: should end with "%s"', [ControlBlockEnd]);

  // remove description block from the SQL command
  Delete(Result, 1, PosDescEnd + 2);
  Result := Trim(Result);
end;

function TVirtualStatement<T>.GetDescription: string;
begin
  Result := FDescription;
end;

class function TVirtualStatement<T>.GetInstance(
  const Container: TContainer;
  const StatementExecutorServiceName: string): TVirtualStatement<T>;
begin
  if StatementExecutorServiceName.IsEmpty() then
    Result := TVirtualStatement<T>.Create(
      Container.Resolve<IStringResourceReader>,
      Container.Resolve<IStatementExecutor>)
  else
    Result := TVirtualStatement<T>.Create(
      Container.Resolve<IStringResourceReader>,
      Container.Resolve<IStatementExecutor>(StatementExecutorServiceName));
end;

function TVirtualStatement<T>.GetIsDefined: boolean;
begin
  Result := Executor.IsBuilt;
end;

function TVirtualStatement<T>.GetIsGetterName(const Name: string): boolean;
begin
  Result := Name.StartsWith(GetterPrefix, true);
end;

function TVirtualStatement<T>.GetIsScalar: boolean;
begin
  Assert(Assigned(ExecMethod));
  Result := ExecMethod.IsFunction;
end;

function TVirtualStatement<T>.GetMappedName(
  const Name: string;
  const IsFunction: boolean): string;
var
  Prefix: string;
begin
  // TODO use actual Maps
  Result := Name.ToUpper;

  // remove getter prefix; TODO setters?
  if IsFunction and GetIsGetterName(Result) then
    Delete (Result, 1, Length(GetterPrefix));

  // in case of procedures and functions we prefix parameter with "P_", e.g. "P_ORDERID"
  if StatementType in [stStoredProc, stFunction] then
    Result := 'P_' + Result;
end;

function TVirtualStatement<T>.GetSQLData: string;
begin
  case StatementType of
    stSequence:
      Result := Format(FResourcedSQL, [
        Copy(StatementData, 1, Pos('.', StatementData) - 1),
        Copy(StatementData, Pos('.', StatementData) + 1, 100)]);
    stFunction:
      Result := Format(FResourcedSQL, [StatementData, FParameterCommaList]);
    stStoredProc:
      Result := StatementData;
    stCommand, stQuery, stScalarQuery:
      Result := FResourcedSQL;
    else
      Assert(false, 'Unimplemented type');
  end;
end;

function TVirtualStatement<T>.GetStatementData: string;
begin
  Result := FStatementData;
end;

function TVirtualStatement<T>.GetStatementType: TStatementType;
begin
  Result := FStatementType;
end;

procedure TVirtualStatement<T>.ProcessAllAttributes;
var
  Context: TRttiContext;
  RttiType: TRttiType;
begin
  Context := TRttiContext.Create;

  RttiType := Context.GetType(TypeInfo(T));

  // process interface-level attributes
  TCollections.CreateList<TCustomAttribute>(RttiType.GetAttributes).ForEach(
    procedure(const Attribute: TCustomAttribute)
    begin
      ProcessAttribute(Attribute);
    end);

  // process all methods (and their attributes)
  TCollections.CreateList<TRttiMethod>(RttiType.GetMethods).ForEach(
    procedure(const Method: TRttiMethod)
    begin
      ProcessMethod(Method);
    end);

  // if no [Execute] found and only one method assume it is the one (unless already assigned to column)
  if not Assigned(ExecMethod) and (FMethods.Count = 1) then
    if FMethods.First.Value.Category = mcNone then
      ExecMethod := FMethods.First.Value;

  // set remaining methods to rows affected or colgetters
  FMethods.Values
    .Where(function(const Value: TMethodDescriptor): Boolean
      begin
        Result := Value.Category = mcNone;
      end)
    .ForEach(procedure(const Value: TMethodDescriptor)
      begin
        if (StatementType = stCommand) and SameText(Value.MappedName, 'ROWSAFFECTED') and (Value.ReturnType = rtInteger) then
          Value.Category := mcRowsAffected
        else
          Value.Category := mcColGetter;
      end);
end;

procedure TVirtualStatement<T>.ProcessAttribute(
  const Attribute: TCustomAttribute;
  const Method: TRttiMethod;
  const MethDesc: TMethodDescriptor);
begin
  // process interface-level attributes (Statement, Description and Map )
  if not Assigned(Method) then
  begin
    // 1. Description
    if Attribute is DescriptionAttribute then
      FDescription := DescriptionAttribute(Attribute).Line
    // 2. Statement
    else if Attribute is StatementAttribute then
    begin
      FStatementType := StatementAttribute(Attribute).&Type;
      FStatementData := StatementAttribute(Attribute).Data;
    end;
    { TODO 3. Map atribute(s) (unlimited number)
    else if Attribute is MapAttribute then
      L.Add(MapAttribute(Attribute).Line)    }
  end

  // method attributes (Execute and Column)
  else
  begin
    // 1. Execute (optional if there is only one method in interface)
    if (Attribute is ExecuteAttribute) and not Assigned(ExecMethod) then
      ExecMethod := MethDesc
    // 2. Column (optional) - overrides automatic name with provided value
    else if (Attribute is ColumnAttribute) then
      MethDesc.MappedName := ColumnAttribute(Attribute).Line
  end;
end;

procedure TVirtualStatement<T>.ProcessMethod(const Method: TRttiMethod);
var
  Attribute : TCustomAttribute;
  MethodDesc: TMethodDescriptor;
  O: TDatasetOperation;
  S: string;
begin
  if not FMethods.TryGetValue(Method.Name, MethodDesc) then
  begin
    Assert(Method.MethodKind in [mkFunction, mkProcedure]);

    MethodDesc := TMethodDescriptor.Create;
    FMethods.Add(Method.Name, MethodDesc);

    MethodDesc.Category := mcNone;
    MethodDesc.OriginalName := Method.Name;
    MethodDesc.Converter := nil;

    if not (Method.MethodKind = mkFunction) then
      MethodDesc.ReturnType := rtNone
    else if SameText(Method.ReturnType.QualifiedName, ValueEnumeratorTypeName) then
    begin
      MethodDesc.ReturnType := rtEnum;
      ExecMethod := MethodDesc;
      MethodDesc.Category := mcExecute;
    end
    else
    begin
      if (Method.ReturnType.TypeKind in [tkInteger, tkInt64]) then
        MethodDesc.ReturnType := rtInteger
      else
        MethodDesc.ReturnType := rtOther;
      MethodDesc.Converter := DataTypeConverter.GetDescriptor(Method.ReturnType);
    end;

    MethodDesc.MappedName := GetMappedName(Method.Name, MethodDesc.IsFunction);
  end;

  // auto describe based in attributes
  TCollections.CreateList<TCustomAttribute>(Method.GetAttributes).ForEach(
    procedure(const Attribute: TCustomAttribute)
    begin
      ProcessAttribute(Attribute, Method, MethodDesc);
    end);

  // assign rest to columns for openables except for scalars
  if StatementType in stOpenable - stScalar then
    for O := TDatasetOperation(1) to High(TDatasetOperation) do
      if SameText(Method.Name, DatasetOperationNames[O]) then
      begin
        Assert(MethodDesc.Category = mcNone);
        Assert(GetIsGetterName(DatasetOperationNames[O]) = MethodDesc.IsFunction);

        MethodDesc.Category := mcDatasetOper;
        MethodDesc.Operation := O;
        MethodDesc.MappedName := EmptyStr;

        Break;
      end;
end;

procedure TVirtualStatement<T>.RaiseError(
  const Msg: string;
  const Args: array of const);
begin
  raise EFidoVirtualStatementError.CreateFmt(Msg, Args);
end;

procedure TVirtualStatement<T>.SetEnumeratorValue(out Result: TValue);
begin
  TestDatasetOpen('SetEnumeratorValue');
  FEnumerator := TValueEnumerator.Create(Self, FDataset);
  Result := TValue.From<IEnumerator>(FEnumerator.Target);
end;

procedure TVirtualStatement<T>.SetExecMethod(const Value: TMethodDescriptor);
begin
  Assert(Assigned(Value) and not Assigned(ExecMethod));
  FExecMethod := Value;
  FExecMethod.Category := mcExecute;
end;

procedure TVirtualStatement<T>.TestDatasetOpen(const MethodToBeCalled: string);
const
  EDatasetClosed = '"%s" not allowed on closed dataset';
begin
  if not Assigned(FDataset) or not FDataset.Active then
    RaiseError(EDatasetClosed, [MethodToBeCalled]);
end;

procedure TVirtualStatement<T>.ValidateStatement;
begin
  if not (StatementType in stValid) then
    RaiseError('Required "Statement" attribute is missing or unsupported (%d)', [Ord(StatementType)]);

  if not Assigned(ExecMethod) then
    RaiseError('"Execute" attibute or method must be defined', []);

  if FStatementData.IsEmpty then
    RaiseError('"StatementData" cannot be empty', []);

  if (StatementType in stQualified) and (not StatementData.Contains('.')) then
    RaiseError('Fully-qualified name is required (e.g. DEV.PRC_NAME)', []);

  if (StatementType in stScalar) and (not ExecMethod.IsFunction) then
    RaiseError('"%s" must be a function (scalar statement)', [ExecMethod.OriginalName]);

  // test execute for various types
  case StatementType of
    stSequence:
      if not (ExecMethod.ReturnType = rtInteger) then
        RaiseError('"%s" must be a function returning an integer value ', [ExecMethod.OriginalName]);
    stCommand:
      if ExecMethod.IsFunction and not (ExecMethod.ReturnType = rtInteger) then
        RaiseError('%s must be either 1) a procedure or 2) a function returning an integer value (will contain RowsAffected)', [ExecMethod.OriginalName]);
  end;
end;

end.
