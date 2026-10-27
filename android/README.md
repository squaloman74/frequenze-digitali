# Frequenze Digitali per Android

Questa app Flutter include attivazione licenza, dashboard di telemetria,
letture del microfono e del magnetometro quando disponibili, calibrazione e
report finale PDF con statistiche. La dashboard offre grafici della frequenza
derivata dal modello di Lorenz, forma d'onda audio e spettrogramma FFT con
scale temporali, frequenziali e d'intensità in dBFS.
La build beta mostra la versione 26 e include un modulo feedback che apre il
menu di condivisione del dispositivo; il feedback viene inviato solo se il
tester sceglie un'app e conferma la condivisione.

Le viste audio richiedono l'avvio del microfono e il relativo permesso.
La calibrazione è abilitata solo mentre il microfono è attivo. La frequenza di
Lorenz è un valore del modello matematico, non una misura ambientale. La
disponibilità del microfono e del magnetometro nel simulatore dipende dalla sua
configurazione; l'app mostra un messaggio quando non riceve campioni audio.
I pulsanti delle viste restano disponibili nella barra inferiore della
dashboard. Gli eventi non vengono mostrati come registro live: sono conservati
in memoria e inclusi nel report finale PDF. Il report riassume frequenza,
livelli audio e campo magnetico disponibili, oltre agli eventi recenti.
Gli avvisi sonori sono attivi per impostazione predefinita quando viene
rilevata una componente stabile a 50/60 Hz. Si possono disattivare e regolare
dal 10% al 100% nella sezione del microfono; il volume iniziale è 65% e segue
anche il volume degli allarmi del dispositivo.

Per ogni aggiornamento beta, incrementare il numero dopo `+` in `version`
(`pubspec.yaml`), compilare una nuova APK e distribuirla ai tester firmata con
la stessa chiave della versione installata. Gli aggiornamenti distribuiti
manualmente non si installano da soli.

## Avvio e test

```powershell
flutter run
flutter analyze
flutter test
flutter build apk --debug
flutter build apk --release
```

L'APK di debug viene generato in
`build/app/outputs/flutter-apk/app-debug.apk`. Il build release locale usa la
chiave debug di Gradle e non è adatto alla distribuzione sul Play Store.

## Loghi

- `assets/lorenz-circle.png`: logo circolare usato nell'header Flutter e come
  base per le icone launcher Android.
- `assets/lorenz-wordmark.png`: logo completo usato nella schermata iniziale.
- `android/app/src/main/res/drawable-nodpi/launch_logo.png`: logo splash
  nativo Android.

Il package Android è `it.frequenzedigitali.frequenze_digitali`. Per pubblicare
una release serviranno una chiave di firma Android dedicata e la configurazione
di release appropriata.
