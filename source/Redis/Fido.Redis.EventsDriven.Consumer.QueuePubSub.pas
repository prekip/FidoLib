(*
 * Copyright 2022 Mirko Bianco (email: writetomirko@gmail.com)
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

unit Fido.Redis.EventsDriven.Consumer.QueuePubSub;

interface

uses
  System.Classes,
  System.SysUtils,
  System.Threading,
  System.NetEncoding,

  Spring,
  Spring.Collections,

  Redis.Commons,
  Redis.Command,
  Redis.Client,

  Fido.JSON.Marshalling,
  Fido.DesignPatterns.Retries,
  Fido.EventsDriven.Consumer.PubSub.Intf,
  Fido.EventsDriven.Utils,

  Fido.Redis.Client.Intf;

type
  TRedisEventsDrivenQueuePubSubConsumer = class(TInterfacedObject, IEventsDrivenPubSubConsumer)
  private
    FRedisClientFactoryFunc: TFunc<IFidoRedisClient>;
    FTasks: IDictionary<string, ITask>;
    FClosing: Boolean;

    procedure TryPop(const RedisClient: IFidoRedisClient; const Key: string; const OnNotify: TProc<string, string>);
  public
    constructor Create(const RedisClientFactoryFunc: TFunc<IFidoRedisClient>);

    procedure Subscribe(const Channel: string; const EventName: string; OnNotify: TProc<string, string>);
    procedure Unsubscribe(const Channel: string; const EventName: string);

    procedure Stop;
  end;

implementation

{ TRedisEventsDrivenQueuePubSubConsumer }

procedure TRedisEventsDrivenQueuePubSubConsumer.TryPop(
  const RedisClient: IFidoRedisClient;
  const Key: string;
  const OnNotify: TProc<string, string>);
var
  EncodedValue: Nullable<string>;
  Payload: string;
begin
  EncodedValue := '';

  // Skip channel opening message
  if Key.Equals(TGuid.Empty.ToString) then
    Exit;

  EncodedValue := Retries.Run<Nullable<string>>(
    function: Nullable<string>
    begin
      Result := RedisClient.RPOP(Key);
    end);

  if not EncodedValue.HasValue then
    Exit;

  Payload := TNetEncoding.Base64.Decode(EncodedValue);
  OnNotify(Key, Payload);
end;

procedure TRedisEventsDrivenQueuePubSubConsumer.Stop;
begin
  FClosing := True;
end;

constructor TRedisEventsDrivenQueuePubSubConsumer.Create(const RedisClientFactoryFunc: TFunc<IFidoRedisClient>);
begin
  inherited Create;

  Guard.CheckNotNull(RedisClientFactoryFunc, 'RedisClientFactoryFunc');
  FRedisClientFactoryFunc := RedisClientFactoryFunc;

  FTasks := TCollections.CreateDictionary<string, ITask>;
  FClosing := False;
end;

procedure TRedisEventsDrivenQueuePubSubConsumer.Subscribe(
  const Channel: string;
  const EventName: string;
  OnNotify: TProc<string, string>);
var
  Key: string;
begin
  Key := TEventsDrivenUtilities.FormatKey(Channel, EventName);
  FTasks.Items[Key] := TTask.Run(
    procedure
    var
      Client: IFidoRedisClient;
    begin
      Client := FRedisClientFactoryFunc();
      Client.SUBSCRIBE(
        Key,
        procedure(key: string; QueueKey: string)
        begin
          TryPop(FRedisClientFactoryFunc(), QueueKey, OnNotify);
        end,
        function: Boolean
        begin
          Result := Assigned(Self) and (not FClosing);
        end);
      Client := nil;
    end);
end;

procedure TRedisEventsDrivenQueuePubSubConsumer.Unsubscribe(const Channel, EventName: string);
begin
  FTasks.Remove(TEventsDrivenUtilities.FormatKey(Channel, EventName));
end;

end.
