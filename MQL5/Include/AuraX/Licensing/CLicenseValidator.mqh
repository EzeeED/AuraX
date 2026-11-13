//+------------------------------------------------------------------+
//| CLicenseValidator.mqh — Validación de licencia EmaRiskPro        |
//|                                                                  |
//| Política: FAIL-CLOSED — sin verificación válida, no opera.       |
//|                                                                  |
//| SOLO PARA EAs. WebRequest() no funciona en indicadores MQL5      |
//| (error 4014). El producto licenciado debe ser un EA.            |
//|                                                                  |
//| Flujo de Check():                                                |
//|   1. GET servidor (200) → guarda caché → retorna resultado       |
//|   2. Sin servidor + caché fresco (< 24 h) → usa caché           |
//|   3. Sin servidor + caché extendido (< 48 h, solo si era valid)  |
//|      → gracia offline; si el último estado fue inválido → bloquea|
//|   4. Sin caché → fail-closed                                     |
//|                                                                  |
//| Claves de producto:  SCAN | ERISK | TRADESTREAK                  |
//|                                                                  |
//| Prerrequisito: agregar https://delorrio.com en                  |
//|   MT5 → Herramientas → Opciones → Asesores Expertos → URLs Web   |
//|                                                                  |
//| API reference: docs/mt5-demo-real-mode.md (mode=REAL/DEMO v5.98)  |
//+------------------------------------------------------------------+

#define LICENSE_SERVER    "https://delorrio.com"

#define LIC_TIMEOUT_MS    5000     // timeout WebRequest (5 s)
#define LIC_CACHE_TTL_S   86400    // caché fresco: 24 h
#define LIC_STALE_TTL_S   172800   // caché extendido: 48 h (solo si era valid)
#define LIC_RECHECK_S     3600     // re-validar cada 1 h

// Clave del checksum del caché offline (issue #60). Compilada en el .ex5 — extraíble con
// esfuerzo de reversing, pero cierra el bypass trivial (editar un .txt y refrescar el ts
// a mano). El límite de seguridad REAL sigue siendo el server; esto solo protege la
// ventana offline. No mover al repo público ni a docs.
#define LIC_CACHE_KEY     "dlc_lic_c9e41b7a2f8d5063"

//+------------------------------------------------------------------+
//| SLicenseResponse — resultado de la validación                    |
//|   valid      — true: puede operar                                |
//|   status     — "active"|"expiring"|"expired"|"revoked"|""        |
//|   product    — "SCAN"|"ERISK"|"ECAL"|"ELITE"|""                 |
//|   expires_at — fecha ISO 8601 o ""                              |
//|   message    — texto para Alert() o Print()                      |
//|   fromCache  — true si viene del caché local                    |
//+------------------------------------------------------------------+
struct SLicenseResponse
{
   bool   valid;
   string status;
   string product;
   string expires_at;
   string message;
   bool   fromCache;
   // Campos de integración (server 2026-07+; ausentes en server viejo → defaults).
   // NO se cachean (_SaveCache/_LoadCache intactos): offline ⇒ false/"" — fail-closed
   // correcto para Telegram (enviar requiere red igual) y sin falso aviso de update.
   string latest_version;    // última versión publicada en ea_releases ("" si no hay)
   bool   update_available;  // true si la versión enviada está atrasada
   bool   telegram_enabled;  // true si el rol del usuario (admin/collaborator) habilita señales
};

//+------------------------------------------------------------------+
//| CLicenseValidator — valida licencia online con caché offline     |
//+------------------------------------------------------------------+
class CLicenseValidator
{
public:
   //+----------------------------------------------------------------+
   //| Constructor                                                     |
   //| serverUrl — URL base sin path ni slash final                   |
   //| product   — "SCAN" | "ERISK" | "ECAL"                         |
   //+----------------------------------------------------------------+
   CLicenseValidator(const string serverUrl, const string product);

   //+----------------------------------------------------------------+
   //| Check — valida licencia (fail-closed). Llamar desde un EA.     |
   //+----------------------------------------------------------------+
   SLicenseResponse Check();

   //+----------------------------------------------------------------+
   //| ShouldRevalidate — true si pasó más de 1 h desde el último     |
   //| Check() exitoso. Usar en OnTimer para re-validar.             |
   //+----------------------------------------------------------------+
   bool ShouldRevalidate() const;

   //+----------------------------------------------------------------+
   //| SetVersion — versión del EA ("2.27"). Se envía como &version=  |
   //| en la validación para tracking y aviso de update. "" (default) |
   //| = no se envía — comportamiento idéntico al histórico.          |
   //+----------------------------------------------------------------+
   void SetVersion(const string version) { m_version = version; }

private:
   string   m_serverUrl;
   string   m_product;
   string   m_version;
   string   m_cacheFile;
   datetime m_lastCheck;

   bool   _RequestServer(SLicenseResponse &result);
   bool   _LoadCache(SLicenseResponse &result, bool staleOk);
   void   _SaveCache(const SLicenseResponse &result);
   void   _ParseJson(const string &json, SLicenseResponse &result);
   string _JsonStr(const string &json, const string &key) const;
   bool   _JsonBool(const string &json, const string &key) const;
   string _Checksum(const string ts, const string valid, const string status,
                    const string product, const string expires) const;
};

//+------------------------------------------------------------------+
//|                    IMPLEMENTACIÓN                                |
//+------------------------------------------------------------------+

CLicenseValidator::CLicenseValidator(const string serverUrl,
                                     const string product)
   : m_serverUrl(serverUrl),
     m_product(product),
     m_version(""),
     m_lastCheck(0)
{
   long acct = AccountInfoInteger(ACCOUNT_LOGIN);
   m_cacheFile = "aurax_lic_" + IntegerToString(acct)
               + "_" + product + ".txt";
}

//+------------------------------------------------------------------+

SLicenseResponse CLicenseValidator::Check()
{
   SLicenseResponse result;
   ZeroMemory(result);

   // 1. Consultar servidor — fuente de verdad (incluye revocación/expiración)
   if(_RequestServer(result))
   {
      _SaveCache(result);
      m_lastCheck = TimeCurrent();
      return result;
   }
   string netError = result.message;

   // 2. Sin servidor — caché fresco (< 24 h)
   SLicenseResponse cached;
   ZeroMemory(cached);
   if(_LoadCache(cached, false))
   {
      cached.fromCache = true;
      m_lastCheck = TimeCurrent();
      return cached;
   }

   // 3. Sin caché fresco — caché extendido (< 48 h). Si el último estado fue
   //    inválido (revocado/expirado), mantiene el bloqueo.
   SLicenseResponse stale;
   ZeroMemory(stale);
   if(_LoadCache(stale, true))
   {
      stale.fromCache = true;
      m_lastCheck = TimeCurrent();
      stale.message = stale.valid
         ? "Modo offline (gracia 48 h)"
         : "Licencia inválida (último estado conocido)";
      return stale;
   }

   // 4. Sin caché → fail-closed
   result.valid   = false;
   result.message = "No se pudo verificar la licencia: " + netError;
   return result;
}

//+------------------------------------------------------------------+

bool CLicenseValidator::ShouldRevalidate() const
{
   if(m_lastCheck == 0) return true;
   return (TimeCurrent() - m_lastCheck) >= LIC_RECHECK_S;
}

//+------------------------------------------------------------------+
//| _GetAccountMode — detecta REAL vs DEMO                             |
//+------------------------------------------------------------------+
string _GetAccountMode()
{
   ENUM_ACCOUNT_TRADE_MODE tradeMode = (ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE);
   return (tradeMode == ACCOUNT_TRADE_MODE_DEMO) ? "DEMO" : "REAL";
}

//+------------------------------------------------------------------+

bool CLicenseValidator::_RequestServer(SLicenseResponse &result)
{
   long   acct = AccountInfoInteger(ACCOUNT_LOGIN);
   string mode = _GetAccountMode();
   string url  = m_serverUrl + "/api/validate-license"
               + "?account_mt5=" + IntegerToString(acct)
               + "&product="     + m_product
               + "&mode="        + mode;
   // Solo si el EA configuró su versión — servers/EAs viejos siguen igual
   if(StringLen(m_version) > 0)
      url += "&version=" + m_version;

   string reqHeaders = "";
   char   postData[];
   char   responseData[];
   string respHeaders;

   int httpCode = WebRequest("GET", url, reqHeaders, LIC_TIMEOUT_MS,
                             postData, responseData, respHeaders);

   if(httpCode == -1)
   {
      int err = GetLastError();
      result.valid = false;
      if(err == 4060)
         result.message = "URL no autorizada — agregar " + m_serverUrl + " en MT5 URLs Web";
      else if(err == 4014)
         result.message = "WebRequest no disponible (err 4014) — requiere EA, no indicador";
      else
         result.message = "Error de red (" + IntegerToString(err) + ")";
      return false;
   }

   if(httpCode != 200)
   {
      result.valid   = false;
      result.message = "HTTP " + IntegerToString(httpCode);
      return false;
   }

   string json = CharArrayToString(responseData, 0, WHOLE_ARRAY, CP_UTF8);
   _ParseJson(json, result);
   return true;
}

//+------------------------------------------------------------------+

bool CLicenseValidator::_LoadCache(SLicenseResponse &result, bool staleOk)
{
   if(!FileIsExist(m_cacheFile, FILE_COMMON)) return false;

   int fh = FileOpen(m_cacheFile, FILE_READ | FILE_TXT | FILE_COMMON);
   if(fh == INVALID_HANDLE) return false;

   string tsStr      = FileReadString(fh);
   string tsLocStr   = FileReadString(fh);
   string validStr   = FileReadString(fh);
   result.status     = FileReadString(fh);
   result.product    = FileReadString(fh);
   result.expires_at = FileReadString(fh);
   result.message    = FileReadString(fh);
   string stored_chk = FileReadString(fh);
   FileClose(fh);

   // Checksum OBLIGATORIO (issue #60): sin checksum, sin match o sin poder calcularlo,
   // el archivo NO vale y se borra. Hasta v6.38/v2.38 un archivo sin la línea de
   // checksum se aceptaba tal cual — el "fail-closed" de la cabecera era fail-open
   // editando un .txt. El hash lleva clave compilada y está atado a la cuenta y a la
   // máquina (_Checksum), así que el archivo tampoco es portable. Cachés del formato
   // viejo (djb2, sin tsLocal) fallan acá y se regeneran en la próxima validación online.
   string expected = _Checksum(tsStr + "|" + tsLocStr, validStr, result.status,
                               result.product, result.expires_at);
   if(StringLen(stored_chk) == 0 || StringLen(expected) == 0 || stored_chk != expected)
   {
      FileDelete(m_cacheFile, FILE_COMMON);
      return false;
   }

   // Edad = MÁXIMO de los dos relojes (issue #61). TimeCurrent es la hora del último
   // tick del broker: sin conexión NO AVANZA — la gracia de 24/48 h no expiraba nunca
   // justo en el único escenario que la motiva (offline). TimeLocal avanza siempre y se
   // compara contra su propio timestamp guardado (sin sesgo de zona horaria). Residual
   // conocido: retrasar el reloj de Windows a mano sigue estirando la gracia — con el
   // checksum con clave ya no se puede hacer editando el archivo, y el server re-manda
   // la verdad en la primera validación online.
   datetime saved    = (datetime)StringToInteger(tsStr);
   datetime savedLoc = (datetime)StringToInteger(tsLocStr);
   long     ageSrv   = (long)(TimeCurrent() - saved);
   long     ageLoc   = (long)(TimeLocal()   - savedLoc);
   long     age      = MathMax(ageSrv, ageLoc);
   if(age < 0)   // ambos relojes detrás del timestamp guardado → manipulación
   {
      FileDelete(m_cacheFile, FILE_COMMON);
      return false;
   }
   bool fresh    = (age <= LIC_CACHE_TTL_S);
   bool extended = (age <= LIC_STALE_TTL_S);

   if(!fresh && !staleOk) return false;
   if(!extended)          return false;

   result.valid = (validStr == "1");
   return true;
}

//+------------------------------------------------------------------+

void CLicenseValidator::_SaveCache(const SLicenseResponse &result)
{
   // Dos timestamps (issue #61): TimeCurrent (reloj del broker) y TimeLocal (reloj de la
   // máquina) — la carga compara cada uno contra su propio reloj y toma el máximo.
   string tsStr    = IntegerToString((long)TimeCurrent());
   string tsLocStr = IntegerToString((long)TimeLocal());
   string validStr = (result.valid ? "1" : "0");

   int fh = FileOpen(m_cacheFile, FILE_WRITE | FILE_TXT | FILE_COMMON);
   if(fh == INVALID_HANDLE) return;

   FileWriteString(fh, tsStr             + "\n");
   FileWriteString(fh, tsLocStr          + "\n");
   FileWriteString(fh, validStr          + "\n");
   FileWriteString(fh, result.status     + "\n");
   FileWriteString(fh, result.product    + "\n");
   FileWriteString(fh, result.expires_at + "\n");
   FileWriteString(fh, result.message    + "\n");
   FileWriteString(fh, _Checksum(tsStr + "|" + tsLocStr, validStr, result.status,
                                 result.product, result.expires_at) + "\n");
   FileClose(fh);
}

//+------------------------------------------------------------------+

string CLicenseValidator::_Checksum(const string ts, const string valid,
                                     const string status, const string product,
                                     const string expires) const
{
   // SHA-256 con clave compilada, atado a la CUENTA y a la MÁQUINA (issue #60):
   //   - la clave no viaja en el archivo → el ts no se puede refrescar a mano
   //     (el djb2 anterior era público y sin secreto: recalculable por cualquiera);
   //   - ACCOUNT_LOGIN → el caché de una cuenta licenciada no sirve para otra;
   //   - TERMINAL_COMMONDATA_PATH → copiar el archivo a otra máquina lo invalida.
   // La clave como prefijo Y sufijo bloquea extensión de hash. Si CryptEncode falla,
   // se devuelve "" y el caller rechaza el caché — fail-closed también acá.
   string payload = LIC_CACHE_KEY + "|" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))
                  + "|" + TerminalInfoString(TERMINAL_COMMONDATA_PATH)
                  + "|" + ts + "|" + valid + "|" + status + "|" + product + "|" + expires
                  + "|" + LIC_CACHE_KEY;
   uchar data[], key[], hash[];
   StringToCharArray(payload, data, 0, StringLen(payload), CP_UTF8);
   if(CryptEncode(CRYPT_HASH_SHA256, data, key, hash) <= 0) return "";
   string hex = "";
   for(int i = 0; i < ArraySize(hash); i++)
      hex += StringFormat("%02X", hash[i]);
   return hex;
}

//+------------------------------------------------------------------+

void CLicenseValidator::_ParseJson(const string &json, SLicenseResponse &result)
{
   result.valid      = _JsonBool(json, "valid");
   result.status     = _JsonStr(json,  "status");
   result.product    = _JsonStr(json,  "product");
   result.expires_at = _JsonStr(json,  "expires_at");
   result.message    = _JsonStr(json,  "message");
   result.fromCache  = false;
   // Claves ausentes (server viejo) → ""/false — degradación limpia
   result.latest_version   = _JsonStr(json,  "latest_version");
   result.update_available = _JsonBool(json, "update_available");
   result.telegram_enabled = _JsonBool(json, "telegram_enabled");
}

//+------------------------------------------------------------------+
//| _JsonTrim — tolera espacios en JSON                               |
//+------------------------------------------------------------------+
string _JsonTrim(const string &s)
{
   int start = 0, end = StringLen(s) - 1;
   while(start <= end && (s[start] == ' ' || s[start] == '\t' || s[start] == '\n' || s[start] == '\r'))
      start++;
   while(end >= start && (s[end] == ' ' || s[end] == '\t' || s[end] == '\n' || s[end] == '\r'))
      end--;
   return (start > end) ? "" : StringSubstr(s, start, end - start + 1);
}

//+------------------------------------------------------------------+
//| _JsonStr — parser flexible: tolera espacios alrededor de :       |
//+------------------------------------------------------------------+
string CLicenseValidator::_JsonStr(const string &json, const string &key) const
{
   string searchKey = "\"" + key + "\"";
   int keyIdx = StringFind(json, searchKey);
   if(keyIdx < 0) return "";

   // Buscar ':' después de la key (con espacios)
   int colonIdx = StringFind(json, ":", keyIdx + StringLen(searchKey));
   if(colonIdx < 0) return "";

   // Buscar '"' que abre el valor (con espacios)
   int valStart = StringFind(json, "\"", colonIdx);
   if(valStart < 0) return "";

   // Buscar '"' que cierra el valor
   int valEnd = StringFind(json, "\"", valStart + 1);
   if(valEnd < 0) return "";

   string rawVal = StringSubstr(json, valStart + 1, valEnd - valStart - 1);
   return _JsonTrim(rawVal);
}

//+------------------------------------------------------------------+
//| _JsonBool — parser flexible: tolera "true", "1", espacios        |
//+------------------------------------------------------------------+
bool CLicenseValidator::_JsonBool(const string &json, const string &key) const
{
   string searchKey = "\"" + key + "\"";
   int keyIdx = StringFind(json, searchKey);
   if(keyIdx < 0) return false;

   // Buscar ':' después de la key
   int colonIdx = StringFind(json, ":", keyIdx + StringLen(searchKey));
   if(colonIdx < 0) return false;

   // Buscar el valor (puede ser "true"/"false" entre comillas O true/false sin comillas)
   int valStart = colonIdx + 1;

   // Skipear espacios
   while(valStart < StringLen(json) && (json[valStart] == ' ' || json[valStart] == '\t' || json[valStart] == '\n' || json[valStart] == '\r'))
      valStart++;

   if(valStart >= StringLen(json)) return false;

   // Caso 1: valor entre comillas ("true" o "false")
   if(json[valStart] == '"')
   {
      int valEnd = StringFind(json, "\"", valStart + 1);
      if(valEnd < 0) return false;
      string val = StringSubstr(json, valStart + 1, valEnd - valStart - 1);
      return (StringCompare(val, "true", false) == 0 || val == "1");
   }

   // Caso 2: booleano sin comillas (true, false, 1, 0)
   // Extraer hasta el próximo carácter separador (coma, cierre, espacio, newline)
   int valEnd = valStart;
   while(valEnd < StringLen(json) && json[valEnd] != ',' && json[valEnd] != '}' && json[valEnd] != ' ' && json[valEnd] != '\n' && json[valEnd] != '\r')
      valEnd++;

   string val = StringSubstr(json, valStart, valEnd - valStart);
   return (StringCompare(val, "true", false) == 0 || val == "1");
}
