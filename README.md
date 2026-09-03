# PodElas

Aplicativo móvel de proteção e apoio para mulheres. O PodElas reúne recursos de
alerta de emergência, compartilhamento de localização, contatos de confiança e
informação sobre violência contra a mulher em uma única experiência.

> **Importante:** o PodElas é um recurso complementar de segurança. Ele não
> substitui a polícia, o serviço de emergência local, o Ligue 180 ou uma rede
> de apoio. Teste os fluxos antes de usar e mantenha os contatos cadastrados
> atualizados.

## Para que serve

O app foi pensado para ajudar uma usuária a pedir ajuda rapidamente quando
estiver em uma situação de risco. Com uma conta configurada, ela pode:

- acionar um alerta pelo botão SOS;
- enviar uma mensagem personalizada pelo WhatsApp para o primeiro guardião
	cadastrado;
- anexar ao alerta um link com a localização GPS atual;
- ativar o alerta com quatro agitações fortes do celular;
- manter o monitoramento de agitação em segundo plano por meio de um serviço
	persistente do Android;
- entrar em um modo camuflado que apresenta uma calculadora após uma situação
	de pânico ou por acionamento manual;
- cadastrar guardiões, editar o nome e a mensagem de emergência;
- consultar notícias e materiais de orientação sobre violência contra a mulher;
- visualizar estatísticas informativas sobre violência e feminicídio.

O Android também pode ser configurado para usar o SOS nativo do aparelho. O
aplicativo pode observar notificações relacionadas a SOS, quando a permissão
específica do Android foi concedida, e reagir a esse evento.

## Como funciona o alerta

1. A usuária cadastra uma conta, seus dados e pelo menos um guardião.
2. Ao tocar no SOS, o app solicita a localização atual e monta a mensagem
	 configurada com um link do Google Maps.
3. O WhatsApp é aberto para o primeiro guardião. A usuária deve confirmar o
	 envio no próprio WhatsApp.
4. A ação também é registrada na coleção `alertas_sos` do Firestore, junto com
	 o usuário, tipo de gatilho, telefone, localização e horário.

No modo de pânico, o app limpa os formulários em memória, encerra a sessão e
abre a calculadora camuflada. O alerta por agitação usa quatro movimentos
fortes em uma janela de dois segundos. Se o GPS estiver indisponível ou sem
permissão, o código usa um link de localização padrão (`0,0`), portanto a
permissão de localização deve ser testada antes de depender do recurso.

## Telas e perfis

- **Início:** notícias selecionadas, links para as matérias completas e opção
	de favoritar itens durante a sessão.
- **Estatísticas:** indicadores e gráficos estáticos sobre violência contra a
	mulher, com fontes apresentadas na tela.
- **Login/Perfil:** cadastro e login por CPF ou telefone, gerenciamento dos
	guardiões e preferências do SOS.
- **Modo camuflado:** calculadora exibida para ocultar a tela principal.
- **Painel administrativo:** conta reservada ao e-mail
	`admin@podelas.com.br`, com visualização dos alertas registrados.

## Tecnologias

- Flutter e Dart;
- Android nativo com Kotlin;
- Firebase Authentication para autenticação;
- Cloud Firestore para usuários, configurações, guardiões e alertas;
- `sensors_plus` para o acelerômetro;
- `geolocator` para a localização;
- `flutter_background_service` e notificações locais para o monitoramento em
	segundo plano;
- `notification_listener_service` para integração opcional com notificações de
	SOS do Android;
- `url_launcher` para WhatsApp, telefone e matérias externas;
- `shared_preferences` para preferências e estado de emergência local.

## Pré-requisitos

- Flutter SDK instalado e configurado;
- Android Studio ou outro ambiente com Android SDK;
- JDK 17;
- um dispositivo Android ou emulador com sensores e localização;
- um projeto Firebase com Authentication (e-mail/senha) e Cloud Firestore
	habilitados;
- WhatsApp instalado no dispositivo para testar o envio direto.

## Configuração do projeto

Este repositório contém o código principal Dart e arquivos Android, mas a
estrutura apresentada não inclui `pubspec.yaml` nem `firebase_options.dart`.
Esses arquivos são obrigatórios para uma compilação Flutter completa.

1. Coloque `main.dart` na estrutura de um projeto Flutter e confirme que ele é
	 o ponto de entrada do aplicativo.
2. Adicione ao `pubspec.yaml` as dependências importadas em `main.dart`, como
	 `firebase_core`, `firebase_auth`, `cloud_firestore`, `sensors_plus`,
	 `geolocator`, `url_launcher`, `flutter_background_service`,
	 `flutter_local_notifications`, `permission_handler`, `shared_preferences`,
	 `android_intent_plus` e `notification_listener_service`.
3. Configure o Firebase com FlutterFire CLI para gerar `firebase_options.dart`:

	 ```bash
	 dart pub global activate flutterfire_cli
	 flutterfire configure
	 ```

4. No Firebase Console, habilite o provedor **E-mail/senha** no Authentication
	 e crie o banco do Cloud Firestore.
5. Revise as regras do Firestore antes de publicar. Usuários devem acessar
	 apenas os próprios dados; o painel administrativo deve ter autorização
	 baseada em uma regra segura, e não somente no endereço de e-mail usado pela
	 interface.
6. Instale as dependências e execute o app:

	 ```bash
	 flutter pub get
	 flutter run
	 ```

Para o monitoramento funcionar, conceda localização e notificações no primeiro
acesso. A leitura de notificações e o SOS nativo também exigem ativação manual
nas configurações de Segurança e Emergência do Android. O comportamento pode
variar conforme fabricante e versão do sistema.

## Modelo de dados usado

### `usuarios/{uid}`

O app grava os dados básicos da usuária, a lista `contatos_emergencia` e o
objeto `configuracoes_emergencia`, que contém:

- `shake_sos_ativo`;
- `gravacao_audio_sos`;
- `disparo_silencioso`;
- `mensagem_sos`.

### `alertas_sos/{id}`

Cada alerta pode conter `uid`, nome, CPF, telefone, `localizacao`,
`tipo_gatilho` e `timestamp` do servidor.

## Limitações atuais

- O envio do WhatsApp é iniciado pelo app, mas depende da confirmação da
	usuária no WhatsApp e da disponibilidade do aplicativo.
- O fluxo principal envia para o primeiro guardião; os demais contatos ficam
	cadastrados para gerenciamento, mas não são disparados em sequência nesse
	fluxo.
- Notícias, estatísticas e favoritos são mantidos localmente no código e não
	formam um CMS ou uma fonte de dados atualizada automaticamente.
- A opção de gravação de áudio aparece nas configurações, mas não há captura e
	envio de áudio implementados no fluxo visível analisado.
- A conta administrativa e as regras do Firebase precisam ser endurecidas
	antes de qualquer uso real com dados pessoais.

## Testes recomendados

Antes de distribuir uma versão, teste em um aparelho físico:

- cadastro, login, logout e recuperação após reiniciar o app;
- permissão negada, GPS desligado e localização indisponível;
- envio para um guardião com e sem WhatsApp instalado;
- SOS por botão, agitação em primeiro plano e agitação em segundo plano;
- ativação do modo camuflado e retorno à tela principal;
- comportamento após bloquear a tela;
- regras de acesso ao Authentication e ao Firestore;
- diferentes versões e fabricantes Android.

## Status

Protótipo funcional em desenvolvimento. A configuração do ambiente Flutter,
Firebase, permissões Android e regras de segurança ainda precisa ser concluída
e validada antes de uso em produção.  BUNGAS
