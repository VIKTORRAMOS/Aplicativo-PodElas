import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:geolocator/geolocator.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:notification_listener_service/notification_listener_service.dart';

import 'firebase_options.dart';

// ====================================================================
// CONFIGURAÇÃO DO SERVIÇO EM SEGUNDO PLANO
// ====================================================================
Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'sos_foreground',
    'Monitoramento SOS',
    description: 'Mantém a detecção de emergência ativa',
    importance: Importance.high,
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: 'sos_foreground',
      initialNotificationTitle: 'Proteção PodElas',
      initialNotificationContent: 'Monitorando emergências no bolso',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  bool isShakeAtivoBg = true;
  int shakeCountBg = 0;
  DateTime? ultimoShakeBackground;

  // Atualizador
  Timer.periodic(const Duration(seconds: 2), (timer) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    isShakeAtivoBg = prefs.getBool('shake_sos_ativo') ?? true;
  });

  userAccelerometerEventStream().listen((UserAccelerometerEvent event) async {
    if (!isShakeAtivoBg) return;

    double forcaAgito = sqrt(
      event.x * event.x + event.y * event.y + event.z * event.z,
    );

    if (forcaAgito > 20.0) {
      final agora = DateTime.now();

      if (ultimoShakeBackground == null ||
          agora.difference(ultimoShakeBackground!) >
              const Duration(seconds: 2)) {
        shakeCountBg = 1;
      } else {
        shakeCountBg++;
      }
      ultimoShakeBackground = agora;

      if (shakeCountBg >= 4) {
        shakeCountBg = 0;

        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('emergencia_ativada_bloqueio', true);

        HapticFeedback.heavyImpact();
        service.invoke('emergencia_acionada_externa');
      }
    }
  });

  Timer.periodic(const Duration(seconds: 3), (timer) async {
    final bool granted =
        await NotificationListenerService.isPermissionGranted();
    if (granted) {
      timer.cancel();
      NotificationListenerService.notificationsStream.listen((event) async {
        if (event.packageName == null) return;
        final pacote = event.packageName!.toLowerCase();
        final titulo = (event.title ?? '').toLowerCase();
        final texto = (event.content ?? '').toLowerCase();

        bool isSosNativo =
            pacote.contains('emergency') ||
            pacote.contains('safety') ||
            pacote.contains('sos') ||
            titulo.contains('sos') ||
            titulo.contains('emergência') ||
            titulo.contains('emergencia') ||
            texto.contains('localização') ||
            texto.contains('emergência') ||
            texto.contains('emergencia');

        if (isSosNativo) {
          debugPrint("🚨 GATILHO SOS DETECTADO PELO ANDROID!");
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool('emergencia_ativada_bloqueio', true);
          service.invoke('emergencia_acionada_externa');
        }
      });
    }
  });
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  return true;
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await initializeService();
  runApp(const PodElasApp());
}

class PodElasApp extends StatelessWidget {
  const PodElasApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PodElas',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          primary: Colors.deepPurple,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF8F7FC),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int _indiceAtual = 0;
  StreamSubscription<UserAccelerometerEvent>? _shakeSubscription;

  // Controladores
  final TextEditingController _relatoController = TextEditingController();
  final TextEditingController _loginIdentificadorController =
      TextEditingController();
  final TextEditingController _nomeController = TextEditingController();
  final TextEditingController _cpfController = TextEditingController();
  final TextEditingController _telefoneController = TextEditingController();
  final TextEditingController _senhaController = TextEditingController();
  final TextEditingController _mensagemSosController = TextEditingController(
    text: '🚨 SOCORRO! Estou em perigo e preciso de ajuda urgente.',
  );

  bool _isLoggedIn = false;
  bool _isAdmin = false; // Controle de acesso do Painel Admin
  bool _isCadastrando = false;
  bool _ocultarSenha = true;
  bool _isLoading = false;
  bool _modoCamufladoAtivo = false;

  bool _shakeSosAtivo = true;
  bool _gravacaoAudioSos = true;
  bool _disparoSilencioso = false;

  String _nomeUsuarioLogado = '';
  String _cpfUsuarioLogado = '';
  String _telefoneUsuarioLogado = '';
  List<Map<String, dynamic>> _contatosEmergencia = [];

  final List<Map<String, dynamic>> _noticias = [
    {
      'id': '1',
      'titulo':
          'Agosto Lilás: Mês de proteção e combate à violência contra a mulher',
      'resumo': 'Conheça as ações de conscientização, canais de apoio e medidas protetivas em todo o Brasil.',
      'data': 'Hoje',
      'fonte': 'Ministério dos Direitos Humanos',
      'url': 'https://www.gov.br/mdh/pt-br/assuntos/noticias/2023/agosto/agosto-lilas-mes-de-conscientizacao-pelo-fim-da-violencia-contra-a-mulher',
      'favoritado': false,
    },
    {
      'id': '2',
      'titulo': 'Lei Maria da Penha: Como identificar os 5 tipos de violência',
      'resumo': 'Aprenda a reconhecer sinais de violência física, psicológica, patrimonial, moral e sexual.',
      'data': 'Ontem',
      'fonte': 'Instituto Maria da Penha',
      'url': 'https://www.institutomariadapenha.org.br/lei-11340/tipos-de-violencia.html',
      'favoritado': false,
    },
    {
      'id': '3',
      'titulo': 'Ligue 180: Canal gratuito, anônimo e disponível 24h por dia',
      'resumo': 'Orientações sobre direitos da mulher, denúncias e acolhimento especializado.',
      'data': 'Há 2 dias',
      'fonte': 'Gov.br Mulher',
      'url': 'https://www.gov.br/mulheres/pt-br/ligue180',
      'favoritado': false,
    },
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ouvirEstadoAutenticacao();
    _verificarPrimeiroAcesso();
    _checarStatusDeEmergenciaBloqueada();
    _iniciarDetectorDeAgitoNoApp();

    FlutterBackgroundService().on('emergencia_acionada_externa').listen((
      event,
    ) {
      if (mounted) {
        _executarPanicWipe(gatilhoInterno: false);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _shakeSubscription?.cancel();
    _relatoController.dispose();
    _loginIdentificadorController.dispose();
    _nomeController.dispose();
    _cpfController.dispose();
    _telefoneController.dispose();
    _senhaController.dispose();
    _mensagemSosController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checarStatusDeEmergenciaBloqueada();
    }
  }

  // ====================================================================
  // REGISTRA A AÇÃO SOS NO PAINEL DE ADMIN (FIRESTORE)
  // ====================================================================
  Future<void> _registrarAcaoSOS(String tipoGatilho) async {
    final user = FirebaseAuth.instance.currentUser;
    // Evita registrar ações se for o admin testando
    if (user == null || user.email == 'admin@podelas.com.br') return;

    try {
      final linkMapsReal = await _obterLinkLocalizacaoReal();
      await FirebaseFirestore.instance.collection('alertas_sos').add({
        'uid': user.uid,
        'nome': _nomeUsuarioLogado,
        'cpf': _cpfUsuarioLogado,
        'telefone': _telefoneUsuarioLogado,
        'localizacao': linkMapsReal,
        'tipo_gatilho': tipoGatilho,
        'timestamp': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('Erro ao registrar alerta SOS: $e');
    }
  }

  void _iniciarDetectorDeAgitoNoApp() {
    DateTime? ultimoShakeApp;
    int shakeCountApp = 0;

    _shakeSubscription = userAccelerometerEventStream().listen((
      UserAccelerometerEvent event,
    ) {
      if (!_shakeSosAtivo) return;

      double forcaAgito = sqrt(
        event.x * event.x + event.y * event.y + event.z * event.z,
      );

      if (forcaAgito > 20.0) {
        final agora = DateTime.now();
        if (ultimoShakeApp == null ||
            agora.difference(ultimoShakeApp!) > const Duration(seconds: 2)) {
          shakeCountApp = 1;
        } else {
          shakeCountApp++;
        }
        ultimoShakeApp = agora;

        if (shakeCountApp >= 4) {
          shakeCountApp = 0;
          debugPrint("🚨 AGITO FORTE DETECTADO DENTRO DO APP!");
          _executarPanicWipe(gatilhoInterno: true);
        }
      }
    });
  }

  Future<void> _checarStatusDeEmergenciaBloqueada() async {
    final prefs = await SharedPreferences.getInstance();
    bool emPanico = prefs.getBool('emergencia_ativada_bloqueio') ?? false;

    if (emPanico) {
      await FirebaseAuth.instance.signOut();
      if (mounted) {
        setState(() {
          _modoCamufladoAtivo = true;
        });
      }
    }
  }

  Future<void> _verificarPrimeiroAcesso() async {
    final prefs = await SharedPreferences.getInstance();
    bool jaAbriu = prefs.getBool('primeiro_acesso_concluido') ?? false;

    if (!jaAbriu) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _exibirModalDePermissoes(prefs);
      });
    }
  }

  void _exibirModalDePermissoes(SharedPreferences prefs) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.security, color: Colors.deepPurple),
            SizedBox(width: 8),
            Text('Proteção Total Ativa', style: TextStyle(fontSize: 16)),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'O nosso aplicativo trabalha junto com a emergência do seu celular. Precisamos de 2 autorizações:',
              style: TextStyle(fontSize: 13),
            ),
            SizedBox(height: 12),
            ListTile(
              leading: Icon(Icons.location_on, color: Colors.red),
              title: Text(
                'GPS',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              subtitle: Text(
                'Para envio de socorro.',
                style: TextStyle(fontSize: 11),
              ),
              contentPadding: EdgeInsets.zero,
            ),
            ListTile(
              leading: Icon(Icons.mark_email_read, color: Colors.blue),
              title: Text(
                'Acesso às Notificações',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              subtitle: Text(
                'Para esconder seus rastros caso a emergência ocorra com a tela bloqueada.',
                style: TextStyle(fontSize: 11),
              ),
              contentPadding: EdgeInsets.zero,
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await [Permission.location, Permission.notification].request();
              final bool granted =
                  await NotificationListenerService.isPermissionGranted();
              if (!granted) {
                await NotificationListenerService.requestPermission();
              }
              await prefs.setBool('primeiro_acesso_concluido', true);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.deepPurple,
              foregroundColor: Colors.white,
            ),
            child: const Text('Entendi, Quero Permitir'),
          ),
        ],
      ),
    );
  }

  Future<void> _abrirConfiguracoesSosNativo() async {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.power_settings_new, color: Colors.red),
            SizedBox(width: 8),
            Text('SOS Nativo do Android', style: TextStyle(fontSize: 16)),
          ],
        ),
        content: const Text(
          '1. Procure pela opção "SOS de Emergência" ou "Segurança e Emergência".\n'
          '2. Ative a chave "Usar SOS de emergência".\n'
          '3. MUITO IMPORTANTE: Desative o "Alarme de contagem regressiva" para que o pedido de ajuda seja silencioso.\n'
          '4. Em "Pedir ajuda", cadastre o 190 ou os seus Guardiões.',
          style: TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              if (Platform.isAndroid) {
                try {
                  const AndroidIntent intent = AndroidIntent(
                    action: 'android.settings.EMERGENCY_SOS_SETTINGS',
                  );
                  await intent.launch();
                } catch (e) {
                  try {
                    const AndroidIntent fallbackIntent = AndroidIntent(
                      action: 'android.settings.SECURITY_SETTINGS',
                    );
                    await fallbackIntent.launch();
                  } catch (e2) {
                    const AndroidIntent generalIntent = AndroidIntent(
                      action: 'android.settings.SETTINGS',
                    );
                    await generalIntent.launch();
                  }
                }
              } else {
                if (mounted)
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Função suportada apenas no Android.'),
                    ),
                  );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Ir para Configurações'),
          ),
        ],
      ),
    );
  }

  Future<void> _executarPanicWipe({bool gatilhoInterno = true}) async {
    HapticFeedback.heavyImpact();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('emergencia_ativada_bloqueio', true);

    if (gatilhoInterno) {
      // Registra a Ação no Painel do Admin
      await _registrarAcaoSOS("Modo Pânico / Camuflagem Rápida");
    }

    _relatoController.clear();
    _limparFormularios();
    await FirebaseAuth.instance.signOut();

    if (mounted) {
      setState(() {
        _modoCamufladoAtivo = true;
      });
    }

    if (gatilhoInterno) {
      final linkMapsReal = await _obterLinkLocalizacaoReal();
      final textoCompleto =
          '${_mensagemSosController.text}\n\n📍 Minha localização em tempo real:\n$linkMapsReal';

      String urlAcao =
          'whatsapp://send?text=${Uri.encodeComponent(textoCompleto)}';
      String urlWebAcao =
          'https://api.whatsapp.com/send?text=${Uri.encodeComponent(textoCompleto)}';

      if (_contatosEmergencia.isNotEmpty) {
        String numeroFormatado = _formatarNumeroParaWhatsApp(
          _contatosEmergencia.first['telefone'],
        );
        urlAcao =
            'whatsapp://send?phone=$numeroFormatado&text=${Uri.encodeComponent(textoCompleto)}';
        urlWebAcao =
            'https://wa.me/$numeroFormatado?text=${Uri.encodeComponent(textoCompleto)}';
      }

      final uriUniversal = Uri.parse(urlAcao);
      try {
        if (!await launchUrl(
          uriUniversal,
          mode: LaunchMode.externalApplication,
        )) {
          final uriWeb = Uri.parse(urlWebAcao);
          await launchUrl(uriWeb, mode: LaunchMode.externalApplication);
        }
      } catch (_) {}
    }
  }

  void _ouvirEstadoAutenticacao() {
    FirebaseAuth.instance.authStateChanges().listen((User? user) async {
      if (user != null) {
        // Verifica se é o email reservado para o Admin
        if (user.email == 'admin@podelas.com.br') {
          if (mounted) {
            setState(() {
              _isLoggedIn = true;
              _isAdmin = true;
            });
          }
          return;
        }

        try {
          final doc = await FirebaseFirestore.instance
              .collection('usuarios')
              .doc(user.uid)
              .get();
          if (doc.exists && doc.data() != null) {
            final data = doc.data()!;
            List<Map<String, dynamic>> contatos = [];
            if (data['contatos_emergencia'] != null) {
              contatos = List<Map<String, dynamic>>.from(
                data['contatos_emergencia'],
              );
            }
            bool shake = _shakeSosAtivo;
            bool gravacao = _gravacaoAudioSos;
            bool silencioso = _disparoSilencioso;
            String msgSos = _mensagemSosController.text;

            if (data['configuracoes_emergencia'] != null) {
              final config = Map<String, dynamic>.from(
                data['configuracoes_emergencia'],
              );
              shake = config['shake_sos_ativo'] ?? shake;
              gravacao = config['gravacao_audio_sos'] ?? gravacao;
              silencioso = config['disparo_silencioso'] ?? silencioso;
              msgSos = config['mensagem_sos'] ?? msgSos;
            }

            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool('shake_sos_ativo', shake);

            if (mounted) {
              setState(() {
                _isLoggedIn = true;
                _isAdmin = false;
                _nomeUsuarioLogado = data['nome'] ?? 'Usuária Protegida';
                _cpfUsuarioLogado = data['cpf'] ?? '';
                _telefoneUsuarioLogado = data['telefone'] ?? '';
                _contatosEmergencia = contatos;
                _shakeSosAtivo = shake;
                _gravacaoAudioSos = gravacao;
                _disparoSilencioso = silencioso;
                _mensagemSosController.text = msgSos;
              });
            }
          } else {
            if (mounted)
              setState(() {
                _isLoggedIn = true;
                _isAdmin = false;
              });
          }
        } catch (_) {
          if (mounted)
            setState(() {
              _isLoggedIn = true;
              _isAdmin = false;
            });
        }
      } else {
        if (mounted) {
          setState(() {
            _isLoggedIn = false;
            _isAdmin = false;
            _nomeUsuarioLogado = '';
            _cpfUsuarioLogado = '';
            _telefoneUsuarioLogado = '';
            _contatosEmergencia = [];
          });
        }
      }
    });
  }

  Future<void> _salvarConfiguracoesNoFirestore({
    bool exibirFeedback = false,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null && !_isAdmin) {
      try {
        await FirebaseFirestore.instance
            .collection('usuarios')
            .doc(user.uid)
            .set({
              'configuracoes_emergencia': {
                'shake_sos_ativo': _shakeSosAtivo,
                'gravacao_audio_sos': _gravacaoAudioSos,
                'disparo_silencioso': _disparoSilencioso,
                'mensagem_sos': _mensagemSosController.text.trim(),
              },
              'contatos_emergencia': _contatosEmergencia,
              'nome': _nomeUsuarioLogado,
              'telefone': _telefoneUsuarioLogado,
            }, SetOptions(merge: true));

        if (exibirFeedback && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Alterações salvas com sucesso!'),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 2),
            ),
          );
        }
      } catch (e) {
        if (exibirFeedback && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Erro ao salvar: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  Future<String> _obterLinkLocalizacaoReal() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return 'https://maps.google.com/?q=0,0';

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied)
        return 'https://maps.google.com/?q=0,0';
    }

    if (permission == LocationPermission.deniedForever)
      return 'https://maps.google.com/?q=0,0';

    try {
      Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 8),
        ),
      );
      return 'https://maps.google.com/?q=${position.latitude},${position.longitude}';
    } catch (e) {
      Position? lastKnown = await Geolocator.getLastKnownPosition();
      if (lastKnown != null)
        return 'https://maps.google.com/?q=${lastKnown.latitude},${lastKnown.longitude}';
      return 'https://maps.google.com/?q=0,0';
    }
  }

  String _formatarNumeroParaWhatsApp(String telefone) {
    String apenasDigitos = telefone.replaceAll(RegExp(r'\D'), '');
    if (apenasDigitos.length <= 11 && !apenasDigitos.startsWith('55'))
      apenasDigitos = '55$apenasDigitos';
    return apenasDigitos;
  }

  Future<void> _enviarWhatsappParaTodosOsGuardioes() async {
    if (_contatosEmergencia.isEmpty) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Nenhum guardião cadastrado.'),
            backgroundColor: Colors.red,
          ),
        );
      return;
    }

    // Registra a Ação no Painel do Admin
    await _registrarAcaoSOS("Acionamento Principal (Botão SOS)");

    final linkMapsReal = await _obterLinkLocalizacaoReal();
    final textoCompleto =
        '${_mensagemSosController.text}\n\n📍 Minha localização em tempo real:\n$linkMapsReal';
    final numeroFormatado = _formatarNumeroParaWhatsApp(
      _contatosEmergencia.first['telefone'],
    );
    final uriUniversal = Uri.parse(
      'whatsapp://send?phone=$numeroFormatado&text=${Uri.encodeComponent(textoCompleto)}',
    );

    try {
      if (!await launchUrl(
        uriUniversal,
        mode: LaunchMode.externalApplication,
      )) {
        await launchUrl(
          Uri.parse(
            'https://wa.me/$numeroFormatado?text=${Uri.encodeComponent(textoCompleto)}',
          ),
          mode: LaunchMode.externalApplication,
        );
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro: $e'), backgroundColor: Colors.red),
        );
    }
  }

  Future<void> _enviarWhatsappParaGuardiao({
    required String telefone,
    required String mensagem,
  }) async {
    final linkMapsReal = await _obterLinkLocalizacaoReal();
    final numeroFormatado = _formatarNumeroParaWhatsApp(telefone);
    final textoCompleto =
        '$mensagem\n\n📍 Minha localização em tempo real:\n$linkMapsReal';
    final uri = Uri.parse(
      'https://wa.me/$numeroFormatado?text=${Uri.encodeComponent(textoCompleto)}',
    );
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Não foi possível abrir o WhatsApp.'),
              backgroundColor: Colors.red,
            ),
          );
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro: $e'), backgroundColor: Colors.red),
        );
    }
  }

  Future<void> _abrirLinkNoticia(String url) async {
    try {
      final Uri uri = Uri.parse(url);
      final bool lancou = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!lancou && mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Não foi possível abrir o link.'),
            backgroundColor: Colors.red,
          ),
        );
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Erro ao abrir matéria: $e'),
            backgroundColor: Colors.red,
          ),
        );
    }
  }

  void _alternarFavorito(String id) {
    setState(() {
      int index = _noticias.indexWhere((n) => n['id'] == id);
      if (index == -1) return;
      bool isFavorito = !_noticias[index]['favoritado'];
      _noticias[index]['favoritado'] = isFavorito;
      var item = _noticias.removeAt(index);
      if (isFavorito) {
        _noticias.insert(0, item);
      } else {
        _noticias.add(item);
      }
    });
  }

  void _saidaRapida() => SystemNavigator.pop();

  Future<void> _submeterAutenticacao() async {
    final senha = _senhaController.text.trim();
    if (_isCadastrando) {
      final nome = _nomeController.text.trim();
      final cpf = _cpfController.text.replaceAll(RegExp(r'\D'), '').trim();
      final telefone = _telefoneController.text
          .replaceAll(RegExp(r'\D'), '')
          .trim();

      if (nome.isEmpty || cpf.isEmpty || telefone.isEmpty || senha.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Preencha todos os campos.'),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }
      setState(() => _isLoading = true);
      final emailFicticio = "$cpf@agostolilas.com.br";
      try {
        UserCredential userCredential = await FirebaseAuth.instance
            .createUserWithEmailAndPassword(
              email: emailFicticio,
              password: senha,
            );
        await FirebaseFirestore.instance
            .collection('usuarios')
            .doc(userCredential.user!.uid)
            .set({
              'nome': nome,
              'cpf': cpf,
              'telefone': telefone,
              'contatos_emergencia': [],
              'configuracoes_emergencia': {
                'shake_sos_ativo': true,
                'gravacao_audio_sos': true,
                'disparo_silencioso': false,
                'mensagem_sos':
                    '🚨 SOCORRO! Estou em perigo e preciso de ajuda urgente.',
              },
              'data_cadastro': FieldValue.serverTimestamp(),
            });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Cadastro concluído com sucesso!'),
              backgroundColor: Colors.green,
            ),
          );
          _limparFormularios();
        }
      } on FirebaseAuthException catch (e) {
        String mensagem = 'Erro no cadastro.';
        if (e.code == 'email-already-in-use')
          mensagem = 'Este CPF já está cadastrado.';
        else if (e.code == 'weak-password')
          mensagem = 'A senha deve ter no mínimo 6 caracteres.';
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(mensagem), backgroundColor: Colors.red),
          );
      } finally {
        if (mounted) setState(() => _isLoading = false);
      }
    } else {
      final identificadorStr = _loginIdentificadorController.text.trim();
      final identificador = identificadorStr.replaceAll(RegExp(r'\D'), '');

      if (identificadorStr.isEmpty || senha.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Informe CPF/Telefone/Admin e senha.'),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }

      setState(() => _isLoading = true);

      // Lógica Secreta do Admin
      String emailFicticio;
      bool isAdminAttempt = false;
      if (identificadorStr.toLowerCase() == 'admin') {
        emailFicticio = "admin@podelas.com.br";
        isAdminAttempt = true;
      } else {
        if (identificador.isEmpty) {
          setState(() => _isLoading = false);
          return;
        }
        emailFicticio = "$identificador@agostolilas.com.br";
      }

      try {
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: emailFicticio,
          password: senha,
        );
        _limparFormularios();
      } on FirebaseAuthException catch (e) {
        // Auto-cria a conta admin na primeira vez que ela tentar logar e não existir
        if (e.code == 'user-not-found' && isAdminAttempt) {
          try {
            await FirebaseAuth.instance.createUserWithEmailAndPassword(
              email: emailFicticio,
              password: senha,
            );
            _limparFormularios();
          } catch (err) {
            if (mounted)
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Erro ao criar admin: $err'),
                  backgroundColor: Colors.red,
                ),
              );
          }
        } else {
          String mensagem = 'Credenciais incorretas.';
          if (e.code == 'user-not-found' ||
              e.code == 'wrong-password' ||
              e.code == 'invalid-credential')
            mensagem = 'Credenciais inválidas.';
          if (mounted)
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(mensagem), backgroundColor: Colors.red),
            );
        }
      } finally {
        if (mounted) setState(() => _isLoading = false);
      }
    }
  }

  void _limparFormularios() {
    _nomeController.clear();
    _cpfController.clear();
    _telefoneController.clear();
    _senhaController.clear();
    _loginIdentificadorController.clear();
  }

  Future<void> _fazerLogout() async {
    await FirebaseAuth.instance.signOut();
    if (mounted)
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Você saiu da sua conta.')));
  }

  void _dialogAdicionarContato() {
    final nomeContatoCtrl = TextEditingController();
    final telContatoCtrl = TextEditingController();
    final parentescoCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.person_add_alt_1, color: Colors.deepPurple),
            SizedBox(width: 8),
            Text('Novo Guardião', style: TextStyle(fontSize: 18)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nomeContatoCtrl,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Nome',
                  prefixIcon: Icon(Icons.person),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: telContatoCtrl,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'WhatsApp com DDD',
                  prefixIcon: Icon(Icons.phone),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: parentescoCtrl,
                decoration: const InputDecoration(
                  labelText: 'Parentesco (ex: Mãe)',
                  prefixIcon: Icon(Icons.favorite_border),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () {
              if (nomeContatoCtrl.text.trim().isNotEmpty &&
                  telContatoCtrl.text.trim().isNotEmpty) {
                setState(() {
                  _contatosEmergencia.add({
                    'nome': nomeContatoCtrl.text.trim(),
                    'telefone': telContatoCtrl.text.trim(),
                    'parentesco': parentescoCtrl.text.trim().isEmpty
                        ? 'Confiança'
                        : parentescoCtrl.text.trim(),
                  });
                });
                _salvarConfiguracoesNoFirestore(exibirFeedback: true);
                Navigator.pop(ctx);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.deepPurple,
              foregroundColor: Colors.white,
            ),
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
  }

  void _dialogAlterarNome() {
    final novoNomeCtrl = TextEditingController(text: _nomeUsuarioLogado);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Editar Nome Completo'),
        content: TextField(
          controller: novoNomeCtrl,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Nome Completo',
            prefixIcon: Icon(Icons.person_outline),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () {
              if (novoNomeCtrl.text.trim().isNotEmpty) {
                setState(() => _nomeUsuarioLogado = novoNomeCtrl.text.trim());
                _salvarConfiguracoesNoFirestore(exibirFeedback: true);
                Navigator.pop(ctx);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.deepPurple,
              foregroundColor: Colors.white,
            ),
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
  }

  void _dialogAlterarSenha() {
    final novaSenhaCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Alterar Senha de Acesso'),
        content: TextField(
          controller: novaSenhaCtrl,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Nova Senha (mín. 6 caracteres)',
            prefixIcon: Icon(Icons.lock_outline),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (novaSenhaCtrl.text.trim().length >= 6) {
                try {
                  await FirebaseAuth.instance.currentUser?.updatePassword(
                    novaSenhaCtrl.text.trim(),
                  );
                  if (mounted) {
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Senha atualizada com sucesso!'),
                        backgroundColor: Colors.green,
                      ),
                    );
                  }
                } catch (e) {
                  if (mounted)
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Erro: $e'),
                        backgroundColor: Colors.red,
                      ),
                    );
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.deepPurple,
              foregroundColor: Colors.white,
            ),
            child: const Text('Atualizar Senha'),
          ),
        ],
      ),
    );
  }

  void _dialogAtualizarTelefone() {
    final novoTelCtrl = TextEditingController(text: _telefoneUsuarioLogado);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Atualizar Telefone'),
        content: TextField(
          controller: novoTelCtrl,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(
            labelText: 'Novo Telefone com DDD',
            prefixIcon: Icon(Icons.phone),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () {
              if (novoTelCtrl.text.trim().isNotEmpty) {
                setState(
                  () => _telefoneUsuarioLogado = novoTelCtrl.text.trim(),
                );
                _salvarConfiguracoesNoFirestore(exibirFeedback: true);
                Navigator.pop(ctx);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.deepPurple,
              foregroundColor: Colors.white,
            ),
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
  }

  void _triggerEmergencyAlert() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.red, size: 28),
            SizedBox(width: 8),
            Text(
              'Alerta de Emergência',
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Mensagem:\n"${_mensagemSosController.text}"',
              style: const TextStyle(fontSize: 12, color: Colors.black87),
            ),
            const SizedBox(height: 10),
            const Row(
              children: [
                Icon(Icons.location_on, color: Colors.red, size: 16),
                SizedBox(width: 4),
                Text(
                  'Sua localização GPS atual será anexada.',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.red,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Guardiões cadastrados: ${_contatosEmergencia.length}',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.deepPurple,
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.pop(context);
                _enviarWhatsappParaTodosOsGuardioes();
              },
              icon: const Icon(
                Icons.send_rounded,
                color: Colors.white,
                size: 18,
              ),
              label: const Text('DISPARAR PARA O GUARDIÃO PRINCIPAL'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green.shade700,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(42),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_modoCamufladoAtivo) {
      return CalculadoraCamufladaScreen(
        onDesbloquear: () async {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool('emergencia_ativada_bloqueio', false);
          setState(() => _modoCamufladoAtivo = false);
        },
      );
    }

    // SE O USUÁRIO LOGADO FOR O ADMIN, EXIBE O PAINEL DE CONTROLE EXCLUSIVO
    if (_isAdmin) {
      return AdminPanelScreen(onLogout: _fazerLogout);
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'PodElas',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            Text(
              'Proteção à Mulher',
              style: TextStyle(fontSize: 11, color: Colors.white70),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on, color: Colors.amber),
            tooltip: 'Gatilho de Emergência',
            onPressed: () => _executarPanicWipe(gatilhoInterno: true),
          ),
          IconButton(
            icon: const Icon(Icons.calculate_outlined),
            tooltip: 'Camuflar',
            onPressed: () => setState(() => _modoCamufladoAtivo = true),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Fechar',
            onPressed: _saidaRapida,
          ),
        ],
      ),
      body: IndexedStack(
        index: _indiceAtual,
        children: [
          _buildNewsTab(),
          _buildEstatisticasTab(),
          _buildAuthAndProfileTab(),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _indiceAtual,
        onTap: (index) {
          setState(() {
            _indiceAtual = index;
          });
        },
        selectedItemColor: Colors.deepPurple,
        unselectedItemColor: Colors.grey.shade600,
        backgroundColor: Colors.white,
        type: BottomNavigationBarType.fixed,
        items: [
          const BottomNavigationBarItem(
            icon: Icon(Icons.home_outlined),
            activeIcon: Icon(Icons.home),
            label: 'Início',
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.insights_outlined),
            activeIcon: Icon(Icons.insights),
            label: 'Estatísticas',
          ),
          BottomNavigationBarItem(
            icon: const Icon(Icons.person_outline),
            activeIcon: const Icon(Icons.person),
            label: _isLoggedIn ? 'Perfil' : 'Login',
          ),
        ],
      ),
    );
  }

  Widget _buildNewsTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'DESTAQUES DA SEMANA',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.deepPurple,
            fontSize: 14,
          ),
        ),
        const SizedBox(height: 12),
        ..._noticias.map((item) {
          return Card(
            elevation: 1.5,
            margin: const EdgeInsets.only(bottom: 12),
            color: item['favoritado'] ? Colors.purple.shade50 : Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: item['favoritado']
                  ? BorderSide(color: Colors.purple.shade200, width: 1.2)
                  : BorderSide(color: Colors.grey.shade200),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.deepPurple.shade50,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              item['fonte'] ?? 'Notícia',
                              style: const TextStyle(
                                fontSize: 10,
                                color: Colors.deepPurple,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            item['data'],
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ),
                      IconButton(
                        constraints: const BoxConstraints(),
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          item['favoritado']
                              ? Icons.bookmark
                              : Icons.bookmark_border,
                          size: 22,
                          color: item['favoritado']
                              ? Colors.deepPurple
                              : Colors.grey,
                        ),
                        onPressed: () => _alternarFavorito(item['id']),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    item['titulo'],
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    item['resumo'],
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.black87,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () => _abrirLinkNoticia(item['url']),
                      icon: const Icon(
                        Icons.open_in_new,
                        size: 14,
                        color: Colors.deepPurple,
                      ),
                      label: const Text(
                        'Ver matéria completa ›',
                        style: TextStyle(
                          color: Colors.deepPurple,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      style: TextButton.styleFrom(padding: EdgeInsets.zero),
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }

  Widget _buildEstatisticasTab() {
    return ListView(
      padding: const EdgeInsets.all(16.0),
      children: [
        const Text(
          'PANORAMA NACIONAL DA VIOLÊNCIA',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.deepPurple,
            fontSize: 15,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Fonte: Anuário Brasileiro de Segurança Pública e FBSP',
          style: TextStyle(fontSize: 11, color: Colors.grey),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _buildMetricCard(
                icon: Icons.timer_outlined,
                titulo: 'A cada 6 horas',
                subtitulo: '1 mulher é vítima de feminicídio no país',
                cor: Colors.red.shade700,
                bgCor: Colors.red.shade50,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildMetricCard(
                icon: Icons.notifications_active_outlined,
                titulo: 'A cada 2 min',
                subtitulo: '1 caso de violência doméstica registrado',
                cor: Colors.deepPurple,
                bgCor: Colors.purple.shade50,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _buildStatCard(
          titulo: 'Autoria dos Casos de Feminicídio',
          descricao: 'Relação do agressor com a vítima',
          icon: Icons.person_off_outlined,
          graficos: [
            _buildBarGauge(
              'Companheiro ou Ex-companheiro',
              0.817,
              '81,7%',
              Colors.deepPurple,
            ),
            const SizedBox(height: 10),
            _buildBarGauge(
              'Outro Parente / Familiar',
              0.124,
              '12,4%',
              Colors.purple.shade400,
            ),
            const SizedBox(height: 10),
            _buildBarGauge(
              'Conhecido ou Amigo',
              0.035,
              '3,5%',
              Colors.purple.shade200,
            ),
            const SizedBox(height: 10),
            _buildBarGauge('Desconhecido', 0.024, '2,4%', Colors.grey.shade500),
          ],
        ),
        const SizedBox(height: 16),
        _buildStatCard(
          titulo: 'Local da Ocorrência',
          descricao: 'Onde os crimes de agressão e feminicídio acontecem',
          icon: Icons.home_outlined,
          graficos: [
            _buildBarGauge(
              'Dentro da Residência (Lar)',
              0.656,
              '65,6%',
              Colors.red.shade600,
            ),
            const SizedBox(height: 10),
            _buildBarGauge(
              'Via Pública / Rua',
              0.212,
              '21,2%',
              Colors.amber.shade800,
            ),
            const SizedBox(height: 10),
            _buildBarGauge(
              'Trabalho e Outros Locais',
              0.132,
              '13,2%',
              Colors.blueGrey,
            ),
          ],
        ),
        const SizedBox(height: 16),
        _buildStatCard(
          titulo: 'Tipos de Violência Notificadas (Ligue 180)',
          descricao: 'Prevalência das queixas recebidas',
          icon: Icons.bar_chart_outlined,
          graficos: [
            _buildBarGauge(
              'Violência Física (Agressões/Lesões)',
              0.485,
              '48,5%',
              Colors.deepPurple,
            ),
            const SizedBox(height: 10),
            _buildBarGauge(
              'Violência Psicológica / Ameaça',
              0.342,
              '34,2%',
              Colors.purple.shade400,
            ),
            const SizedBox(height: 10),
            _buildBarGauge(
              'Violência Patrimonial e Moral',
              0.113,
              '11,3%',
              Colors.purple.shade300,
            ),
            const SizedBox(height: 10),
            _buildBarGauge(
              'Violência Sexual',
              0.060,
              '6,0%',
              Colors.red.shade400,
            ),
          ],
        ),
        const SizedBox(height: 16),
        _buildStatCard(
          titulo: 'Perfil das Vítimas',
          descricao: 'Distribuição por cor/raça e faixa etária',
          icon: Icons.groups_outlined,
          graficos: [
            const Text(
              'Distribuição Racial:',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 6),
            _buildBarGauge(
              'Mulheres Negras (Pretas e Pardas)',
              0.669,
              '66,9%',
              Colors.deepPurple.shade700,
            ),
            const SizedBox(height: 8),
            _buildBarGauge(
              'Mulheres Brancas',
              0.324,
              '32,4%',
              Colors.deepPurple.shade300,
            ),
            const Divider(height: 24),
            const Text(
              'Faixa Etária Principal:',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 6),
            _buildBarGauge('18 a 34 anos', 0.498, '49,8%', Colors.teal),
            const SizedBox(height: 8),
            _buildBarGauge(
              '35 a 49 anos',
              0.312,
              '31,2%',
              Colors.teal.shade300,
            ),
          ],
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.amber.shade50,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.amber.shade300),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, color: Colors.amber.shade900, size: 24),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Atenção ao Risco',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: Colors.amber.shade900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Mais de 70% das vítimas de feminicídio não possuíam Medida Protetiva de Urgência no momento do crime. Registre e proteja-se.',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.black87,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _buildMetricCard({
    required IconData icon,
    required String titulo,
    required String subtitulo,
    required Color cor,
    required Color bgCor,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bgCor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cor.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: cor, size: 22),
          const SizedBox(height: 8),
          Text(
            titulo,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 13,
              color: cor,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitulo,
            style: const TextStyle(
              fontSize: 11,
              color: Colors.black87,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatCard({
    required String titulo,
    required String descricao,
    required IconData icon,
    required List<Widget> graficos,
  }) {
    return Card(
      elevation: 1.5,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: Colors.deepPurple, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    titulo,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              descricao,
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            ...graficos,
          ],
        ),
      ),
    );
  }

  Widget _buildBarGauge(
    String label,
    double percent,
    String displayValue,
    Color color,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Text(
              displayValue,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: percent,
            minHeight: 9,
            backgroundColor: Colors.grey.shade200,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
      ],
    );
  }

  Widget _buildAuthAndProfileTab() {
    if (!_isLoggedIn) return _buildAuthScreen();
    return _buildMeuPerfilScreen();
  }

  Widget _buildMeuPerfilScreen() {
    return ListView(
      padding: const EdgeInsets.all(16.0),
      children: [
        Card(
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 28,
                      backgroundColor: Colors.deepPurple.shade100,
                      child: const Icon(
                        Icons.person,
                        color: Colors.deepPurple,
                        size: 32,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _nomeUsuarioLogado,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.edit_outlined,
                                  size: 18,
                                  color: Colors.deepPurple,
                                ),
                                tooltip: 'Editar Nome',
                                onPressed: _dialogAlterarNome,
                              ),
                            ],
                          ),
                          const Row(
                            children: [
                              Icon(
                                Icons.verified_user,
                                color: Colors.green,
                                size: 14,
                              ),
                              SizedBox(width: 4),
                              Text(
                                'Perfil Sincronizado & Seguro',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.green,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const Divider(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'CPF: $_cpfUsuarioLogado',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.black87,
                      ),
                    ),
                    Text(
                      'Tel: $_telefoneUsuarioLogado',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.black87,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.shield, color: Colors.deepPurple, size: 22),
                        SizedBox(width: 8),
                        Text(
                          'Meus Guardiões',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.add_circle,
                        color: Colors.deepPurple,
                      ),
                      tooltip: 'Adicionar Guardião',
                      onPressed: _dialogAdicionarContato,
                    ),
                  ],
                ),
                const Text(
                  'Pessoas notificadas via WhatsApp com sua localização GPS.',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
                const SizedBox(height: 10),
                if (_contatosEmergencia.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Center(
                      child: Text(
                        'Nenhum guardião cadastrado.',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ),
                  )
                else
                  ..._contatosEmergencia.asMap().entries.map((entry) {
                    int idx = entry.key;
                    var c = entry.value;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.purple.shade50,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.favorite,
                            color: Colors.deepPurple,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${c['nome']} (${c['parentesco']})',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                ),
                                Text(
                                  c['telefone'],
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Colors.black87,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.chat,
                              color: Colors.green,
                              size: 22,
                            ),
                            tooltip: 'Enviar WhatsApp com GPS Real',
                            onPressed: () => _enviarWhatsappParaGuardiao(
                              telefone: c['telefone'],
                              mensagem: _mensagemSosController.text,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.delete_outline,
                              color: Colors.red,
                              size: 18,
                            ),
                            onPressed: () {
                              setState(() => _contatosEmergencia.removeAt(idx));
                              _salvarConfiguracoesNoFirestore(
                                exibirFeedback: true,
                              );
                            },
                          ),
                        ],
                      ),
                    );
                  }),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.sensors, color: Colors.deepPurple, size: 22),
                    SizedBox(width: 8),
                    Text(
                      'Gatilhos de Emergência',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ListTile(
                  leading: const Icon(
                    Icons.power_settings_new,
                    color: Colors.red,
                  ),
                  title: const Text(
                    'Ativar 5 Cliques no Botão Power',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                  subtitle: const Text(
                    'Abre as configurações nativas do seu celular. É o método infalível para pedir socorro com a tela apagada.',
                    style: TextStyle(fontSize: 11),
                  ),
                  contentPadding: EdgeInsets.zero,
                  trailing: ElevatedButton(
                    onPressed: _abrirConfiguracoesSosNativo,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text(
                      'Configurar',
                      style: TextStyle(fontSize: 11),
                    ),
                  ),
                ),
                SwitchListTile(
                  title: const Text(
                    'Shake to SOS (Agitar celular)',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  subtitle: const Text(
                    'Agitar o aparelho dispara a camuflagem na hora!',
                    style: TextStyle(fontSize: 11),
                  ),
                  value: _shakeSosAtivo,
                  activeColor: Colors.deepPurple,
                  contentPadding: EdgeInsets.zero,
                  onChanged: (v) async {
                    setState(() => _shakeSosAtivo = v);
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setBool('shake_sos_ativo', v);
                    _salvarConfiguracoesNoFirestore();
                  },
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _mensagemSosController,
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: 'Mensagem de Socorro Personalizada',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: ElevatedButton.icon(
                    onPressed: () =>
                        _salvarConfiguracoesNoFirestore(exibirFeedback: true),
                    icon: const Icon(Icons.save_outlined, size: 16),
                    label: const Text(
                      'Salvar Mensagem',
                      style: TextStyle(fontSize: 12),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.deepPurple,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(
                      Icons.visibility_off_outlined,
                      color: Colors.deepPurple,
                      size: 22,
                    ),
                    SizedBox(width: 8),
                    Text(
                      'Privacidade & Camuflagem',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ListTile(
                  leading: const Icon(
                    Icons.calculate_outlined,
                    color: Colors.deepPurple,
                  ),
                  title: const Text(
                    'Ativar Modo Calculadora',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                  subtitle: const Text(
                    'Disfarça o app como calculadora. Digite 180= para voltar.',
                    style: TextStyle(fontSize: 11),
                  ),
                  contentPadding: EdgeInsets.zero,
                  trailing: ElevatedButton(
                    onPressed: () => setState(() => _modoCamufladoAtivo = true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.deepPurple,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text(
                      'Camuflar',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(
                    Icons.cleaning_services_outlined,
                    color: Colors.red,
                  ),
                  title: const Text(
                    'Limpar Rastros (Panic Wipe)',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: Colors.red,
                    ),
                  ),
                  subtitle: const Text(
                    'Limpa formulários, desloga e ativa camuflagem instantaneamente.',
                    style: TextStyle(fontSize: 11),
                  ),
                  contentPadding: EdgeInsets.zero,
                  onTap: () => _executarPanicWipe(gatilhoInterno: true),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(
                      Icons.settings_outlined,
                      color: Colors.deepPurple,
                      size: 22,
                    ),
                    SizedBox(width: 8),
                    Text(
                      'Segurança da Conta',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ListTile(
                  leading: const Icon(
                    Icons.lock_reset,
                    color: Colors.deepPurple,
                  ),
                  title: const Text(
                    'Alterar Senha de Acesso',
                    style: TextStyle(fontSize: 13),
                  ),
                  contentPadding: EdgeInsets.zero,
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _dialogAlterarSenha,
                ),
                ListTile(
                  leading: const Icon(
                    Icons.phone_android,
                    color: Colors.deepPurple,
                  ),
                  title: const Text(
                    'Atualizar Número de Telefone',
                    style: TextStyle(fontSize: 13),
                  ),
                  contentPadding: EdgeInsets.zero,
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _dialogAtualizarTelefone,
                ),
                const Divider(),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: _fazerLogout,
                    icon: const Icon(Icons.logout, color: Colors.red, size: 18),
                    label: const Text(
                      'Desconectar da Conta',
                      style: TextStyle(
                        color: Colors.red,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          onPressed: _triggerEmergencyAlert,
          icon: const Icon(Icons.warning_amber_rounded, size: 24),
          label: const Text(
            'ENVIAR PEDIDO DE SOCORRO AGORA',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red,
            foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(52),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _buildAuthScreen() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.deepPurple.shade50,
                shape: BoxShape.circle,
              ),
              child: Icon(
                _isCadastrando
                    ? Icons.person_add_alt_1_rounded
                    : Icons.shield_rounded,
                size: 42,
                color: Colors.deepPurple,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _isCadastrando ? 'CRIAR NOVA CONTA' : 'ACESSO PROTEGIDO',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.deepPurple,
              ),
            ),
            const SizedBox(height: 20),
            Card(
              elevation: 3,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_isCadastrando) ...[
                      TextField(
                        controller: _nomeController,
                        textCapitalization: TextCapitalization.words,
                        decoration: InputDecoration(
                          labelText: 'Nome Completo',
                          prefixIcon: const Icon(Icons.person_outline),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _cpfController,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: 'CPF (apenas números)',
                          prefixIcon: const Icon(Icons.badge_outlined),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _telefoneController,
                        keyboardType: TextInputType.phone,
                        decoration: InputDecoration(
                          labelText: 'Telefone com DDD',
                          prefixIcon: const Icon(Icons.phone_outlined),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                    ] else ...[
                      TextField(
                        controller: _loginIdentificadorController,
                        decoration: InputDecoration(
                          labelText: 'CPF, Telefone ou "admin"',
                          prefixIcon: const Icon(Icons.account_circle_outlined),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],
                    TextField(
                      controller: _senhaController,
                      obscureText: _ocultarSenha,
                      decoration: InputDecoration(
                        labelText: 'Senha de Acesso',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _ocultarSenha
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                          ),
                          onPressed: () =>
                              setState(() => _ocultarSenha = !_ocultarSenha),
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    ElevatedButton(
                      onPressed: _isLoading ? null : _submeterAutenticacao,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.deepPurple,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2.5,
                              ),
                            )
                          : Text(
                              _isCadastrando ? 'CONCLUIR CADASTRO' : 'ENTRAR',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () => setState(() => _isCadastrando = !_isCadastrando),
              child: Text(
                _isCadastrando
                    ? 'Já possui cadastro? Clique aqui para Entrar'
                    : 'Não possui cadastro? Cadastre-se com sigilo',
                style: const TextStyle(
                  color: Colors.deepPurple,
                  fontWeight: FontWeight.bold,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// ====================================================================
/// NOVA TELA: PAINEL DE CONTROLE DO ADMIN (COM NOTIFICAÇÕES)
/// ====================================================================
class AdminPanelScreen extends StatefulWidget {
  final VoidCallback onLogout;
  const AdminPanelScreen({super.key, required this.onLogout});

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen> {
  late StreamSubscription<QuerySnapshot> _alertaSubscription;
  final FlutterLocalNotificationsPlugin _notificacoesLocais =
      FlutterLocalNotificationsPlugin();
  bool _isInitialLoad = true; // Controla para não notificar os alertas que já existiam antes de abrir a tela

  @override
  void initState() {
    super.initState();
    _inicializarNotificacoes();
    _ouvirNovosAlertas();
  }

  // Configura o plugin de notificações para disparar na tela
  Future<void> _inicializarNotificacoes() async {
    const AndroidInitializationSettings androidConfig =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const DarwinInitializationSettings iosConfig =
        DarwinInitializationSettings();
    const InitializationSettings configGeral = InitializationSettings(
      android: androidConfig,
      iOS: iosConfig,
    );

    await _notificacoesLocais.initialize(configGeral);
  }

  // Escuta o banco de dados em tempo real
  void _ouvirNovosAlertas() {
    _alertaSubscription = FirebaseFirestore.instance
        .collection('alertas_sos')
        .orderBy('timestamp', descending: true)
        .snapshots()
        .listen((snapshot) {
          // Se for a primeira vez carregando a tela, apenas carrega a lista e ignora as notificações
          if (_isInitialLoad) {
            _isInitialLoad = false;
            return;
          }

          // Procura por documentos que acabaram de ser adicionados (novos SOS)
          for (var change in snapshot.docChanges) {
            if (change.type == DocumentChangeType.added) {
              final data = change.doc.data() as Map<String, dynamic>;
              final nome = data['nome'] ?? 'Vítima Desconhecida';
              final gatilho = data['tipo_gatilho'] ?? 'Alerta';

              _dispararNotificacaoSonora(nome, gatilho);
            }
          }
        });
  }

  // Constrói e dispara a notificação no celular do admin
  Future<void> _dispararNotificacaoSonora(String nome, String gatilho) async {
    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          'admin_emergencia_canal',
          'Alertas de Emergência Admin',
          channelDescription: 'Avisa o administrador instantaneamente sobre novos pedidos de socorro',
          importance: Importance.max,
          priority: Priority.high,
          color: Colors.red,
          enableVibration: true,
          playSound: true,
        );

    const NotificationDetails detalhes = NotificationDetails(
      android: androidDetails,
    );

    await _notificacoesLocais.show(
      DateTime.now().millisecond, // ID único para não sobrepor notificações
      '🚨 NOVO PEDIDO DE SOCORRO!',
      '$nome acionou o SOS via: $gatilho',
      detalhes,
    );
  }

  @override
  void dispose() {
    _alertaSubscription.cancel(); // Para de escutar o banco ao sair da tela
    super.dispose();
  }

  String formatarData(Timestamp timestamp) {
    final dt = timestamp.toDate();
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year} às ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        title: const Text(
          'Painel Administrativo SOS',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.red.shade800,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sair do Painel',
            onPressed: widget.onLogout,
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('alertas_sos')
            .orderBy('timestamp', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return const Center(child: Text('Erro ao carregar os dados.'));
          }

          final docs = snapshot.data?.docs ?? [];
          if (docs.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.shield_outlined, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text(
                    'Nenhum alerta SOS registrado.',
                    style: TextStyle(color: Colors.grey, fontSize: 16),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: docs.length,
            itemBuilder: (ctx, index) {
              final data = docs[index].data() as Map<String, dynamic>;
              final nome = data['nome'] ?? 'Sem nome';
              final cpf = data['cpf'] ?? 'N/A';
              final telefone = data['telefone'] ?? 'N/A';
              final gatilho = data['tipo_gatilho'] ?? 'Desconhecido';
              final localizacao = data['localizacao'] ?? '';
              final timestamp = data['timestamp'] as Timestamp?;
              final dataHora = timestamp != null
                  ? formatarData(timestamp)
                  : 'Data indisponível';

              return Card(
                elevation: 2,
                margin: const EdgeInsets.only(bottom: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: Colors.red.shade100),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.warning_amber_rounded,
                                color: Colors.red,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                gatilho,
                                style: const TextStyle(
                                  color: Colors.red,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                          Text(
                            dataHora,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.grey,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const Divider(height: 20),
                      Text(
                        'Vítima: $nome',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'CPF: $cpf  •  Tel: $telefone',
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 12),
                      ElevatedButton.icon(
                        onPressed: () async {
                          if (localizacao.isNotEmpty) {
                            try {
                              await launchUrl(
                                Uri.parse(localizacao),
                                mode: LaunchMode.externalApplication,
                              );
                            } catch (_) {}
                          }
                        },
                        icon: const Icon(Icons.location_on, size: 16),
                        label: const Text(
                          'Ver Localização no Mapa',
                          style: TextStyle(fontSize: 12),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue.shade700,
                          foregroundColor: Colors.white,
                          minimumSize: const Size.fromHeight(36),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// ====================================================================
/// TELA DE CALCULADORA FUNCIONAL PARA O MODO CAMUFLADO
/// ====================================================================
class CalculadoraCamufladaScreen extends StatefulWidget {
  final VoidCallback onDesbloquear;
  const CalculadoraCamufladaScreen({super.key, required this.onDesbloquear});

  @override
  State<CalculadoraCamufladaScreen> createState() =>
      _CalculadoraCamufladaScreenState();
}

class _CalculadoraCamufladaScreenState
    extends State<CalculadoraCamufladaScreen> {
  String _display = '0';
  String _codigoDigitado = '';

  void _onBtnPress(String val) {
    setState(() {
      if (val == 'C') {
        _display = '0';
        _codigoDigitado = '';
      } else if (val == '=') {
        if (_codigoDigitado == '180' || _display == '180') {
          widget.onDesbloquear();
          return;
        }
        _display = '0';
        _codigoDigitado = '';
      } else {
        _codigoDigitado += val;
        if (_display == '0') {
          _display = val;
        } else {
          _display += val;
        }
      }
    });
  }

  Widget _btn(String txt, {Color? corFundo, Color? corTexto}) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(4.0),
        child: ElevatedButton(
          onPressed: () => _onBtnPress(txt),
          style: ElevatedButton.styleFrom(
            backgroundColor: corFundo ?? Colors.grey.shade200,
            foregroundColor: corTexto ?? Colors.black87,
            padding: const EdgeInsets.symmetric(vertical: 22),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          child: Text(
            txt,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text(
          'Calculadora',
          style: TextStyle(color: Colors.black87),
        ),
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(24),
                alignment: Alignment.bottomRight,
                child: Text(
                  _display,
                  style: const TextStyle(
                    fontSize: 48,
                    fontWeight: FontWeight.w300,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                children: [
                  Row(
                    children: [
                      _btn(
                        'C',
                        corFundo: Colors.red.shade100,
                        corTexto: Colors.red,
                      ),
                      _btn('('),
                      _btn(')'),
                      _btn('/', corFundo: Colors.orange.shade100),
                    ],
                  ),
                  Row(
                    children: [
                      _btn('7'),
                      _btn('8'),
                      _btn('9'),
                      _btn('x', corFundo: Colors.orange.shade100),
                    ],
                  ),
                  Row(
                    children: [
                      _btn('4'),
                      _btn('5'),
                      _btn('6'),
                      _btn('-', corFundo: Colors.orange.shade100),
                    ],
                  ),
                  Row(
                    children: [
                      _btn('1'),
                      _btn('2'),
                      _btn('3'),
                      _btn('+', corFundo: Colors.orange.shade100),
                    ],
                  ),
                  Row(
                    children: [
                      _btn('0'),
                      _btn('.'),
                      _btn(
                        '=',
                        corFundo: Colors.orange.shade400,
                        corTexto: Colors.white,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
