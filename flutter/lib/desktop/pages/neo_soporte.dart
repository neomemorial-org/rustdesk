import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/formatter/id_formatter.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:http/http.dart' as http;

const _kBroker = 'https://apps-soporte-broker.kc54fe.easypanel.host';
const _kTokenOption = 'neo-broker-token';
const _kTimeout = Duration(seconds: 10);

class _BrokerError implements Exception {
  final int status;
  _BrokerError(this.status);
}

Future<Map<String, dynamic>> _call(String method, String path,
    {Map<String, dynamic>? body, Map<String, String>? headers}) async {
  final uri = Uri.parse('$_kBroker$path');
  final h = {'Content-Type': 'application/json', ...?headers};
  final http.Response resp = method == 'GET'
      ? await http.get(uri, headers: h).timeout(_kTimeout)
      : await http
          .post(uri, headers: h, body: jsonEncode(body ?? {}))
          .timeout(_kTimeout);
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    throw _BrokerError(resp.statusCode);
  }
  if (resp.body.isEmpty) return {};
  final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
  return decoded is Map<String, dynamic> ? decoded : {};
}

String _errorText(Object e, {Map<int, String> byStatus = const {}}) {
  if (e is _BrokerError) {
    return byStatus[e.status] ??
        'El servicio de soporte respondió con un error (${e.status}).';
  }
  return 'No se pudo conectar con el servicio de soporte. Revisá la conexión a internet.';
}

/// Pedido de soporte de la ventana de solo entrante: se envía solo al abrir.
class NeoSolicitarSoporte extends StatefulWidget {
  const NeoSolicitarSoporte({Key? key}) : super(key: key);

  @override
  State<NeoSolicitarSoporte> createState() => _NeoSolicitarSoporteState();
}

class _NeoSolicitarSoporteState extends State<NeoSolicitarSoporte> {
  String? _rid;
  String? _cancel;
  String? _sentPassword;
  String? _error;
  bool _busy = false;
  Timer? _renew;
  // Pedir soporte sin intervención; se apaga al cancelar o ante un error.
  bool _auto = true;
  Timer? _autoTimer;

  @override
  void initState() {
    super.initState();
    gFFI.serverModel.serverPasswd.addListener(_onPasswordChanged);
    _autoTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_auto && _rid == null && !_busy && _ready) _send();
    });
  }

  bool get _ready =>
      int.tryParse(gFFI.serverModel.serverId.text.replaceAll(' ', '')) !=
          null &&
      gFFI.serverModel.serverPasswd.text.length > 1;

  @override
  void dispose() {
    gFFI.serverModel.serverPasswd.removeListener(_onPasswordChanged);
    _renew?.cancel();
    _autoTimer?.cancel();
    super.dispose();
  }

  void _onPasswordChanged() {
    final pw = gFFI.serverModel.serverPasswd.text;
    if (_rid != null && !_busy && pw != _sentPassword && pw.length > 1) {
      _send();
    }
  }

  Future<void> _send() async {
    final key = bind.mainGetBuildinOption(key: 'neo-broker-client-key');
    if (key.isEmpty) {
      setState(() {
        _auto = false;
        _error = 'Falta configurar el servicio de soporte.';
      });
      return;
    }
    final id = gFFI.serverModel.serverId.text.replaceAll(' ', '');
    final pw = gFFI.serverModel.serverPasswd.text;
    if (!_ready) {
      setState(() {
        _auto = true;
        _error = null;
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await _call('POST', '/v1/solicitudes', headers: {
        'X-Client-Key': key
      }, body: {
        'id': id,
        'password': pw,
        'equipo': Platform.localHostname,
        'usuario': Platform.environment['USERNAME'] ?? '',
      });
      _rid = r['rid']?.toString();
      _cancel = r['cancel']?.toString();
      _sentPassword = pw;
      final vence = r['vence_s'];
      _renew?.cancel();
      if (vence is num && vence > 120) {
        _renew = Timer(Duration(seconds: vence.toInt() - 60), () {
          if (_rid != null) _send();
        });
      }
    } catch (e) {
      _rid = null;
      _auto = false;
      _error = _errorText(e, byStatus: {
        401: 'El servicio de soporte rechazó el pedido (clave de cliente inválida).',
        429: 'Demasiados pedidos seguidos. Esperá un minuto y probá de nuevo.',
      });
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _cancelRequest() async {
    final rid = _rid, cancel = _cancel;
    _renew?.cancel();
    setState(() {
      _rid = null;
      _cancel = null;
      _auto = false;
    });
    try {
      await _call('POST', '/v1/solicitudes/cancelar',
          body: {'rid': rid, 'cancel': cancel});
    } catch (_) {
      // El pedido vence solo en el servidor.
    }
  }

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    Widget loading(String text) => Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 10),
            Flexible(child: Text(text, style: small)),
          ],
        );
    final Widget content;
    if (_rid != null) {
      content = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          loading('Soporte solicitado, esperando a un técnico…'),
          TextButton(onPressed: _cancelRequest, child: const Text('Cancelar')),
        ],
      );
    } else if (_auto || _busy) {
      content = Center(child: loading('Solicitando soporte…'));
    } else {
      content = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: double.infinity,
            height: 38,
            child: ElevatedButton(
              onPressed: _send,
              child: Text(_error != null ? 'Reintentar' : 'Solicitar soporte'),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_error!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: small?.copyWith(color: Colors.red)),
            ),
        ],
      );
    }
    // Alto fijo: la ventana de solo entrante se dimensiona con el contenido.
    return Container(
      height: 110,
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      child: content,
    );
  }
}

/// Panel "Pedidos de soporte" de la consola (solo saliente).
class NeoPedidosPanel extends StatefulWidget {
  const NeoPedidosPanel({Key? key}) : super(key: key);

  @override
  State<NeoPedidosPanel> createState() => _NeoPedidosPanelState();
}

class _NeoPedidosPanelState extends State<NeoPedidosPanel> {
  String _token = '';
  bool? _adminConfigured;
  List<Map<String, dynamic>> _items = [];
  String? _error;
  bool _busy = false;
  bool _polling = false;
  Timer? _timer;
  final _p0 = TextEditingController();
  final _p1 = TextEditingController();

  @override
  void initState() {
    super.initState();
    _token = bind.mainGetLocalOption(key: _kTokenOption);
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _tick());
    _tick();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _p0.dispose();
    _p1.dispose();
    super.dispose();
  }

  Map<String, String> get _auth => {'Authorization': 'Bearer $_token'};

  Future<void> _setToken(String token) async {
    _token = token;
    await bind.mainSetLocalOption(key: _kTokenOption, value: token);
  }

  Future<void> _tick() async {
    if (_polling || _busy) return;
    _polling = true;
    try {
      if (_token.isEmpty) {
        if (_adminConfigured == null) {
          final r = await _call('GET', '/v1/estado');
          _adminConfigured = r['admin_configurado'] == true;
          _error = null;
        }
      } else {
        final r = await _call('GET', '/v1/admin/solicitudes', headers: _auth);
        final list = r['solicitudes'];
        _items = list is List
            ? list.whereType<Map<String, dynamic>>().toList()
            : [];
        _error = null;
      }
    } catch (e) {
      if (e is _BrokerError && e.status == 401) {
        await _setToken('');
        _adminConfigured = null;
        _items = [];
        _error = 'La sesión venció. Ingresá la clave de nuevo.';
      } else {
        _error = _errorText(e);
      }
    }
    _polling = false;
    if (mounted) setState(() {});
  }

  Future<void> _submitPassword() async {
    final setup = _adminConfigured == false;
    final pw = _p0.text;
    if (setup && pw.length < 8) {
      setState(() => _error = 'La clave tiene que tener al menos 8 caracteres.');
      return;
    }
    if (setup && pw != _p1.text) {
      setState(() => _error = 'Las dos claves no coinciden.');
      return;
    }
    if (pw.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await _call(
          'POST', setup ? '/v1/admin/setup' : '/v1/admin/login',
          body: {'password': pw});
      final token = r['token']?.toString() ?? '';
      if (token.isEmpty) throw _BrokerError(500);
      await _setToken(token);
      _p0.clear();
      _p1.clear();
    } catch (e) {
      if (e is _BrokerError && e.status == 409) _adminConfigured = true;
      _error = _errorText(e, byStatus: {
        401: 'Clave incorrecta.',
        409: 'La consola ya tiene una clave creada. Ingresala para entrar.',
        429: 'Demasiados intentos. Esperá un minuto y probá de nuevo.',
      });
    }
    _busy = false;
    if (mounted) setState(() {});
    _tick();
  }

  Future<void> _logout() async {
    final auth = _auth;
    await _setToken('');
    setState(() {
      _items = [];
      _adminConfigured = true;
      _error = null;
    });
    try {
      await _call('POST', '/v1/admin/logout', headers: auth);
    } catch (_) {
      // El token local ya se borró.
    }
  }

  Future<void> _attend(Map<String, dynamic> item) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await _call(
          'POST', '/v1/admin/solicitudes/${item['rid']}/atender',
          headers: _auth);
      final id = r['id']?.toString() ?? '';
      final pw = r['password']?.toString() ?? '';
      if (mounted && id.isNotEmpty) {
        connect(context, id, password: pw);
      }
    } catch (e) {
      _error = _errorText(e, byStatus: {
        404: 'Ese pedido ya fue atendido o venció.',
      });
    }
    _busy = false;
    if (mounted) setState(() {});
    _tick();
  }

  String _wait(dynamic s) {
    final n = s is num ? s.toInt() : 0;
    return n < 60 ? 'hace ${n}s' : 'hace ${n ~/ 60} min';
  }

  Widget _passwordForm(BuildContext context) {
    final setup = _adminConfigured == false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(setup
            ? 'Crear clave de la consola (mínimo 8 caracteres)'
            : 'Ingresá la clave de la consola'),
        const SizedBox(height: 8),
        Row(children: [
          SizedBox(
            width: 200,
            child: TextField(
              controller: _p0,
              obscureText: true,
              decoration:
                  const InputDecoration(isDense: true, hintText: 'Clave'),
              onSubmitted: (_) => setup ? null : _submitPassword(),
            ),
          ),
          if (setup) const SizedBox(width: 8),
          if (setup)
            SizedBox(
              width: 200,
              child: TextField(
                controller: _p1,
                obscureText: true,
                decoration: const InputDecoration(
                    isDense: true, hintText: 'Repetir clave'),
                onSubmitted: (_) => _submitPassword(),
              ),
            ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: _busy ? null : _submitPassword,
            child: Text(setup ? 'Crear clave' : 'Entrar'),
          ),
        ]),
      ],
    );
  }

  Widget _list(BuildContext context) {
    if (_items.isEmpty) {
      return Text('No hay pedidos pendientes',
          style: Theme.of(context).textTheme.bodySmall);
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: ListView(
        shrinkWrap: true,
        children: _items
            .map((it) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    Expanded(
                      child: Text(
                        '${formatID(it['id']?.toString() ?? '')}  ·  '
                        '${it['equipo'] ?? ''}  ·  ${it['usuario'] ?? ''}  ·  '
                        '${_wait(it['espera_s'])}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    ElevatedButton(
                      onPressed: _busy ? null : () => _attend(it),
                      child: const Text('Atender'),
                    ),
                  ]),
                ))
            .toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loggedIn = _token.isNotEmpty;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text('Pedidos de soporte',
                  style: Theme.of(context).textTheme.titleLarge),
            ),
            if (loggedIn)
              TextButton(
                  onPressed: _logout, child: const Text('Cerrar sesión')),
          ]),
          const SizedBox(height: 8),
          if (loggedIn)
            _list(context)
          else if (_adminConfigured != null)
            _passwordForm(context)
          else if (_error == null)
            Text('Conectando…', style: Theme.of(context).textTheme.bodySmall),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          const Divider(),
        ],
      ),
    );
  }
}
