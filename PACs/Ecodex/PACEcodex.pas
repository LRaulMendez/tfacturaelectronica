{* *****************************************************************************
  PROYECTO FACTURACION ELECTRONICA
  Copyright (C) 2010-2014 - Bamb� Code SA de CV - Ing. Luis Carrasco

  Esta clase representa la implementaci�n para timbrado de CFDI del proveedor
  Ecodex (http://www.ecodex.com.mx)

  Este archivo pertenece al proyecto de codigo abierto de Bamb� Code:
  http://bambucode.com/codigoabierto

  La licencia de este c�digo fuente se encuentra en:
  http://github.com/bambucode/tfacturaelectronica/blob/master/LICENCIA

  ***************************************************************************** *}

unit PACEcodex;

interface

uses HTTPSend,
     Classes,
     xmldom,
     XMLIntf,
     msxmldom,
     XMLDoc,
     SysUtils,
     ProveedorAutorizadoCertificacion,
     FacturaTipos,
     FETimbreFiscalDigital,
     PAC.Ecodex.ManejadorDeSesion,
     EcodexWsTimbrado,
     FeCFD;

type

 // Excepciones espec�ficas de Ecodex
 EEcodexNoExisteAliasDeLlaveException = class(Exception); // Error c�digo 1001

 {$REGION 'Documentation'}
 ///	<summary>
 ///	  Implementa el servicio de timbrado para CFDI del proveedor "Comercio
 ///	  Digital" (<see href="http://www.comercio-digital.com.mx" />)
 ///	</summary>
 {$ENDREGION}
 TPACEcodex = class(TProveedorAutorizadoCertificacion)
 private
  fCredenciales : TFEPACCredenciales;
  wsTimbradoEcodex: IEcodexServicioTimbrado;
  fManejadorDeSesion : TEcodexManejadorDeSesion;
  function AsignarTimbreDeRespuestaDeEcodex(const aRespuestaTimbrado:
      TEcodexRespuestaTimbrado): TFETimbre;
  procedure ProcesarExcepcionDePAC(const aExcepcion: Exception);
  function getNombre() : string; override;
public
  destructor Destroy(); override;
  procedure AfterConstruction; override;
  procedure AsignarCredenciales(const aCredenciales: TFEPACCredenciales); override;
  function CancelarDocumento(const aDocumento: TTipoComprobanteXML): Boolean; override;
  function TimbrarDocumento(const aDocumento: TTipoComprobanteXML): TFETimbre; override;
  property Nombre : String read getNombre;
 end;

implementation

uses {$IF Compilerversion >= 20} Soap.InvokeRegistry, {$IFEND}
     EcodexWsComun,
     feCFDv32,
     {$IFDEF CODESITE}
     CodeSiteLogging,
     {$ENDIF}
     FacturaReglamentacion;


function TPACEcodex.getNombre() : string;
begin
  Result := 'Ecodex';
end;

destructor TPACEcodex.Destroy();
begin
  FreeAndNil(fManejadorDeSesion);
  // Al ser una interface el objeto TXMLDocument se libera automaticamente por Delphi al dejar de ser usado
  // aunque para asegurarnos hacemos lo siguiente:
  inherited;
end;

procedure TPACEcodex.AfterConstruction;
begin
  // Obtenemos una instancia del WebService de Timbrado de Ecodex
  wsTimbradoEcodex := GetWsEcodexTimbrado;
  fManejadorDeSesion := TEcodexManejadorDeSesion.Create;
end;

procedure TPACEcodex.AsignarCredenciales(const aCredenciales: TFEPACCredenciales);
begin
  fCredenciales := aCredenciales;
  fManejadorDeSesion.AsignarCredenciales(aCredenciales);
end;

function TPACEcodex.AsignarTimbreDeRespuestaDeEcodex(const aRespuestaTimbrado:
    TEcodexRespuestaTimbrado): TFETimbre;
var
  comprobanteTimbrado: IFEXMLComprobanteV32;
  nodoXMLTimbre: IFEXMLtimbreFiscalDigital;
  documentoXMLTimbrado, documentoXMLTimbre: TXmlDocument;
begin
  Assert(aRespuestaTimbrado <> nil, 'La respuesta del servicio de timbrado fue nula');

  // Creamos el documento XML para almacenar el XML del comprobante completo que nos regresa Ecodex
  documentoXMLTimbrado := TXMLDocument.Create(nil);
  documentoXMLTimbrado.Active := True;
  documentoXMLTimbrado.Version := '1.0';
  documentoXMLTimbrado.Encoding := 'utf-8';
  {$IF Compilerversion >= 20}
  // Delphi 2010 y superiores
  documentoXMLTimbrado.XML.Text:=aRespuestaTimbrado.ComprobanteXML.DatosXML;
  {$ELSE}
  documentoXMLTimbrado.XML.Text:=UTF8Encode(aRespuestaTimbrado.ComprobanteXML.DatosXML);
  {$IFEND}

  documentoXMLTimbrado.Active:=True;

  // Convertimos el XML a la interfase del CFD v3.2
  comprobanteTimbrado := GetComprobanteV32(documentoXMLTimbrado);

  // Extraemos solamente el nodo del timbre
  Assert(IFEXMLComprobanteV32(comprobanteTimbrado).Complemento.HasChildNodes,
        'No se recibio correctamente el timbre');
  Assert(IFEXMLComprobanteV32(comprobanteTimbrado).Complemento.ChildNodes.Count = 1,
        'Se debio haber tenido solo el timbre como complemento');

  // Creamos el documento XML solamente del timbre
  documentoXMLTimbre := TXMLDocument.Create(nil);
  documentoXMLTimbre.XML.Text := IFEXMLComprobanteV32(comprobanteTimbrado).Complemento.ChildNodes.First.XML;
  documentoXMLTimbre.Active := True;

  // Convertimos el XML del nodo a la interfase del Timbre v3.2
  nodoXMLTimbre := GetTimbreFiscalDigital(documentoXMLTimbre);

  // Extraemos las propiedades del timbre para regresarlas en el tipo TFETimbre
  Result.Version:=nodoXMLTimbre.Version;
  Result.UUID:=nodoXMLTimbre.UUID;
  Result.FechaTimbrado:=TFEReglamentacion.DeFechaHoraISO8601(nodoXMLTimbre.FechaTimbrado);
  Result.SelloCFD:=nodoXMLTimbre.SelloCFD;
  Result.NoCertificadoSAT:=nodoXMLTimbre.NoCertificadoSAT;
  Result.SelloSAT:=nodoXMLTimbre.SelloSAT;
  Result.XML := nodoXMLTimbre.XML;
end;

procedure TPACEcodex.ProcesarExcepcionDePAC(const aExcepcion: Exception);
var
  mensajeExcepcion: string;
const
  _ECODEX_FUERA_DE_SERVICIO = '(22)';
  _ECODEX_VERSION_NO_SOPORTADA = 'El driver no soporta esta version de cfdi';
  // Algunos errores no regresan c�digo de error, los buscamos por cadena completa
  _ECODEX_RFC_NO_CORRESPONDE = 'El rfc del Documento no corresponde al del encabezado';
  _NO_ECONTRADO = 0;
begin
  mensajeExcepcion := aExcepcion.Message;

  if (aExcepcion Is EEcodexFallaValidacionException) Or (aExcepcion Is EEcodexFallaServicioException) then
  begin
      if (aExcepcion Is EEcodexFallaValidacionException)  then
      begin
        mensajeExcepcion := 'EFallaValidacionException (' + IntToStr(EEcodexFallaValidacionException(aExcepcion).Numero) + ') ' +
                        EEcodexFallaValidacionException(aExcepcion).Descripcion;
      end;

      if (aExcepcion Is EEcodexFallaServicioException)  then
      begin
        mensajeExcepcion := 'EFallaServicioException (' + IntToStr(EEcodexFallaServicioException(aExcepcion).Numero) + ') ' +
                        EEcodexFallaServicioException(aExcepcion).Descripcion;
      end;
  end;

  if AnsiPos(_ECODEX_FUERA_DE_SERVICIO, mensajeExcepcion) > _NO_ECONTRADO then
    raise EPACServicioNoDisponibleException.Create(mensajeExcepcion, 0, True);

  if AnsiPos(_ERROR_SAT_XML_INVALIDO, mensajeExcepcion) > _NO_ECONTRADO then
    raise  ETimbradoXMLInvalidoException.Create(mensajeExcepcion, 301, False);

  if AnsiPos(_ERROR_SAT_SELLO_EMISOR_INVALIDO, mensajeExcepcion) > _NO_ECONTRADO then
    raise ETimbradoSelloEmisorInvalidoException.Create(mensajeExcepcion, 302, False);

  if AnsiPos(_ERROR_SAT_CERTIFICADO_NO_CORRESPONDE, mensajeExcepcion) > _NO_ECONTRADO then
    raise ETimbradoCertificadoNoCorrespondeException.Create(mensajeExcepcion, 303, False);

  if AnsiPos(_ERROR_SAT_CERTIFICADO_REVOCADO, mensajeExcepcion) > _NO_ECONTRADO then
    raise ETimbradoCertificadoRevocadoException.Create(mensajeExcepcion, 304, False);

  if AnsiPos(_ERROR_SAT_FECHA_EMISION_SIN_VIGENCIA, mensajeExcepcion) > _NO_ECONTRADO then
    raise ETimbradoFechaEmisionSinVigenciaException.Create(mensajeExcepcion, 305, False);

  if AnsiPos(_ERROR_SAT_LLAVE_NO_CORRESPONDE, mensajeExcepcion) > _NO_ECONTRADO then
    raise ETimbradoLlaveInvalidaException.Create(mensajeExcepcion, 306, False);

  if AnsiPos(_ERROR_SAT_PREVIAMENTE_TIMBRADO, mensajeExcepcion) > _NO_ECONTRADO then
    raise ETimbradoPreviamenteException.Create(mensajeExcepcion, 307, False);

  if AnsiPos(_ERROR_SAT_CERTIFICADO_NO_FIRMADO_POR_SAT, mensajeExcepcion) > _NO_ECONTRADO then
    raise ETimbradoCertificadoApocrifoException.Create(mensajeExcepcion, 308, False);

  if AnsiPos(_ERROR_SAT_FECHA_FUERA_DE_RANGO, mensajeExcepcion) > _NO_ECONTRADO then
    raise ETimbradoFechaGeneracionMasDe72HorasException.Create(mensajeExcepcion, 401, False);

  if AnsiPos(_ERROR_SAT_REGIMEN_EMISOR_NO_VALIDO, mensajeExcepcion) > _NO_ECONTRADO then
    raise ETimbradoRegimenEmisorNoValidoException.Create(mensajeExcepcion, 402, False);

  if AnsiPos(_ERROR_SAT_FECHA_EMISION_EN_EL_PASADO, mensajeExcepcion) > _NO_ECONTRADO then
    raise ETimbradoFechaEnElPasadoException.Create(mensajeExcepcion, 403, False);

  if AnsiPos(_ECODEX_RFC_NO_CORRESPONDE, mensajeExcepcion) > _NO_ECONTRADO then
    raise EPACTimbradoRFCNoCorrespondeException.Create('El RFC del documento y el del emisor no corresponden', 0, False);

  if AnsiPos(_ECODEX_VERSION_NO_SOPORTADA, mensajeExcepcion) > _NO_ECONTRADO then
    raise EPACTimbradoVersionNoSoportadaPorPACException.Create('Esta version de CFDI no es soportada por ECODEX:' +
                                                              mensajeExcepcion, 0, False);

  // Si llegamos aqui y no se ha lanzado ningun otro error lanzamos el error gen�rico de PAC
  // con la propiedad reintentable en verdadero para que el cliente pueda re-intentar el proceso anterior
  raise ETimbradoErrorGenericoException.Create(mensajeExcepcion, 0, True);
end;

function TPACEcodex.TimbrarDocumento(const aDocumento: TTipoComprobanteXML): TFETimbre;
var
  solicitudTimbrado: TSolicitudTimbradoEcodex;
  respuestaTimbrado: TEcodexRespuestaTimbrado;
  tokenDeUsuario, mensajeFalla: string;
begin
  try
    // 1. Iniciamos una nueva sesion solicitando un nuevo token
    tokenDeUsuario := fManejadorDeSesion.ObtenerNuevoTokenDeUsuario;

    // 1. Creamos la solicitud de timbrado
    solicitudTimbrado := TSolicitudTimbradoEcodex.Create;

    // 2. Asignamos el documento XML
    solicitudTimbrado.ComprobanteXML := TEcodexComprobanteXML.Create;
    solicitudTimbrado.ComprobanteXML.DatosXML := aDocumento;
    solicitudTimbrado.RFC := fCredenciales.RFC;
    solicitudTimbrado.Token := tokenDeUsuario;
    solicitudTimbrado.TransaccionID := fManejadorDeSesion.NumeroDeTransaccion;

    try
      mensajeFalla := '';

      // 3. Realizamos la solicitud de timbrado
      respuestaTimbrado := wsTimbradoEcodex.TimbraXML(solicitudTimbrado);

      // 4. Extraemos las propiedades del timbre de la respuesta del WebService
      Result := AsignarTimbreDeRespuestaDeEcodex(respuestaTimbrado);
      respuestaTimbrado.Free;
    except
      On E:Exception do
        ProcesarExcepcionDePAC(E);
    end;
  finally
    if Assigned(solicitudTimbrado) then
      solicitudTimbrado.Free;
  end;
end;

function TPACEcodex.CancelarDocumento(const aDocumento: TTipoComprobanteXML): Boolean;
var
  timbreUUID, mensajeFalla, tokenDeUsuario: String;
  solicitudCancelacion : TEcodexSolicitudCancelacion;
  respuestaCancelacion : TEcodexRespuestaCancelacion;

  function ExtraerUUID(const aDocumentoTimbrado: TTipoComprobanteXML) : String;
  const
    _LONGITUD_UUID = 36;
  begin
      Result:=Copy(aDocumentoTimbrado,
                   AnsiPos('UUID="', aDocumentoTimbrado) + 6,
                   _LONGITUD_UUID);
  end;

begin
  Result := False;

  // 1. Iniciamos una nueva sesion solicitando un nuevo token
  tokenDeUsuario := fManejadorDeSesion.ObtenerNuevoTokenDeUsuario;

  try
    // 2. Creamos la solicitud de cancelacion
    solicitudCancelacion := TEcodexSolicitudCancelacion.Create;
    solicitudCancelacion.RFC := fCredenciales.RFC;
    solicitudCancelacion.Token := tokenDeUsuario;
    solicitudCancelacion.TransaccionID := fManejadorDeSesion.NumeroDeTransaccion;
    // Ecodex solo requiere que le enviemos el UUID del timbre anterior, lo extraemos para enviarlo
    solicitudCancelacion.UUID := ExtraerUUID(aDocumento);

    try
      mensajeFalla := '';
      respuestaCancelacion := wsTimbradoEcodex.CancelaTimbrado(solicitudCancelacion);

      Result := respuestaCancelacion.Cancelada;
      respuestaCancelacion.Free;
    except
      On E:Exception do
        ProcesarExcepcionDePAC(E);
    end;
  finally
    if Assigned(solicitudCancelacion) then
      solicitudCancelacion.Free;
  end;
end;

end.
