{   Copyright 2008 Jerome

    This file is part of CncNet_XP.

    CncNet_XP is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    CncNet_XP is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with CncNet_XP.  If not, see <http://www.gnu.org/licenses/>.

    The software Jedicut is allowed to statically and dynamically link this library.
}

unit UCom;

interface

uses
  SysUtils, Math, UType, ULib;

//{$DEFINE _DEBUG}

  // Fonction renvoyant le code famille de la dll, ce code indique le type de la dll
  // Les codes possibles :
  // 0 : Dll de communication - Une seule dll charg�e par instance de Jedicut
  // 1 : Dll de lecture SEUL de fichier
  // 2 : Dll de lecture/ecriture de fichier
  function GetDllFamily : byte; export

  procedure GetDescription(Cible : PChar; tailleCible: integer);
  function EmettreBit(bitRotation, bitSens : byte ; vitesse : integer ; chauffe : double) : smallInt; export;
  procedure MoteurOnOff(moteurOn : boolean); export;
  procedure InitialiserChauffeEtCommunication(portBase : word ;
                                              ParamChauffe : TParametreChauffe ;
                                              ParamCommunication : TParametreCommunication ;
                                              Materiau : TMateriau); export;
  function EtatMachine : byte; export;
  function LireChauffeMachine : double; export;
  procedure AdapterOrdres(var ArrayOrdres : TArrayOrdresMoteur); export;

  // New functions to adapt Jedicut capacities (and simplify settings)
  function GetDllAcceptSmoothMove() : smallInt; export;
  function GetDllAcceptHeatingControl() : smallInt; export;
  function GetDllSendExternalTimer() : smallInt; export;
  function GetDllSendHeatingSignal() : smallInt; export;
  function GetDllSendHeatingStatus() : smallInt; export;
  function GetDllAcceptOnOffControl() : smallInt; export;
  function GetDllPicture() : smallInt; export;


  // Fonctions priv�es
//{$IF Defined(_DEBUG)}
//    procedure PortOut(Port : Word; Data : Byte);
//    function PortIn(Port : Word) : Byte;
//{$ELSE}
    procedure PortOut(Port : Word; Data : Byte); stdcall; external 'io.dll';
    function PortIn(Port : Word) : Byte; stdcall; external 'io.dll';
//{$IFEND}

  function CalculerTempsSignalHaut(valChauffe : double) : integer;
  procedure CompresserOrdresMoteur(var ArrayOrdres : TArrayOrdresMoteur);
implementation

const TIME_OUT = 10000;

var
  ParametreChauffe : TParametreChauffe;
  ParametreCommunication : TParametreCommunication;
  MateriauActif : TMateriau;
  periodeChauffe : integer;
  pulseChauffe : integer;
  bSignalChauffeHaut : boolean; // Variable permettant de ne positionner le signal de chauffe qu'une seule fois par p�riodede chauffe
  horloge, ancienneHorloge : byte; // Variable pour d�tecter le signal d'horloge
  portAdresseBase : word; // Adresse de base du port parall�le

// ADRESSE_BASE + 0 : registre de donn�es D0 � D7 (Bit 0 � Bit 7)
// ADRESSE_BASE + 1 : registre de statut /!\ DANGER : LECTURE SEULE /!\
// ADRESSE_BASE + 2 : registre de contr�le

// Signal de chauffe : broche 16 - bit 2 du registre de commande
// Timer : broche 10 - bit 6 du registre de statut
// Moteur On/Off : bit 3 du registre de contr�le
// Retour du signal de chauffe : broche 11 - Registre Statut Bit 7

//{$IF Defined(_DEBUG)}
//  procedure PortOut(Port : Word; Data : Byte);
//  begin
//    // Ecrire dans un fichier les valeurs envoy�s sur le port //
//  end;
//
//  function PortIn(Port : Word) : Byte;
//  begin
//    // $40 pour timer et $20 pour chauffe (active ?)
//    Result := $40; // Non utilis�
//  end;
//{$IFEND}


{-----------------------------------------------------------------}
{ Renvoie le type de la dll }
function GetDllFamily : byte;
begin
  Result := 0;
end;

{-----------------------------------------------------------------}
{ Renvoie la description de la dll }
procedure GetDescription(Cible : PChar; tailleCible: integer);
var
  Description : ShortString;
begin
  Description := 'Protocole utilis� avec la machine CncNet MM2001, compatible Windows XP. Chauffe & utilisation du timer externe. Version 1.6.2';
  StrPLCopy(Cible, Description, tailleCible);
end;

{-----------------------------------------------------------------}
{ M�thode de la dll g�rant l'alimentation des moteurs }
procedure MoteurOnOff(moteurOn : boolean);
var
  value : byte;
begin
  // G�rer l'alimentation des moteurs
    // Sur le registre 2, les bits 0 (broche 1), 1 (b14), 3(b17) sont invers�s.
    // Et pas 2 (b16) et 4 (b?) (les autres ne sont pas utilis�s).
    // Cette inversion n'est pas pris en compte par le plugin, sinon �a doit se coder partout o� le registre 2 est utilis�
    // Ce code n'est pas encore compl�tement param�trable car le registre n'est pas dynamique
  value := Trunc(Int(Power2(2, ParametreCommunication.BitAlimMoteur.iBit)));
  if moteurOn then
  begin
    // Alimenter les moteurs
    PortOut(portAdresseBase + 2, 0); // 0 pour MM2001 - value (Inversion du signal) pour test de la 4xTB6560AHQ
  end else begin
    // Emettre la remise � zero des bits moteurs
    PortOut(portAdresseBase, 0);
    // Couper l'alimentation des moteurs et mettre la chauffe � 0
    PortOut(portAdresseBase + 2, 8); // 8 avant utilisation de la variable ou "value" pour MM2001 ou 0 pour test de la 4xTB6560AHQ
  end;
end;

{-----------------------------------------------------------------}
{ M�thode de la dll d'envoi des bits propre � un type de machine }
function EmettreBit(bitRotation, bitSens : byte ; vitesse : integer ; chauffe : double) : smallInt;
var
  timeOut : integer;
  i : integer;
  pulse : integer;
  stepOk : boolean;
  codeRetour : smallInt;
  tempsBas : integer; // Si pas de timer
const
  OFFSET_SIGNAL_SENS = 50000; // Si pas de timer
  TEMPS_STEP_HAUT = 100000; // Si pas de timer
begin
  stepOk := false;
  pulse := 0;
  timeOut := 0;
  codeRetour := NO_ERROR;

  if (vitesse>=0) then
  begin
    // Si on a choisit l'utilisation du timer externe
    if (ParametreCommunication.synchroniserMoteurAvecTimerExterne) then
    begin
      if vitesse>1 then vitesse := vitesse-1
      else vitesse := 1;
      while (not stepOk) do  // rajouter la condition que vitesse<>0 pour sortir
      begin
        horloge := PortIn(portAdresseBase+1);
        horloge := horloge and $40; // bit 6
        Inc(timeOut);
        if (timeOut>=TIME_OUT) then
        begin
          codeRetour := ERROR_TIME_OUT;
          break;
        end;

        if ((horloge=$40)and(ancienneHorloge=0)) then
        begin
          timeOut := 0;
          Inc(pulseChauffe);
          Inc(pulse);
          if(pulse=vitesse-1)then
          begin
            // Emettre le sens de rotation
            PortOut(portAdresseBase, bitSens);
          end;
          if(pulse=vitesse) then
          begin
            // Emettre l'ordre de rotation + sens
            PortOut(portAdresseBase, bitRotation + bitSens);
          end;
          if(pulse=vitesse+2)then
          begin
            // Emettre le sens de rotation
            PortOut(portAdresseBase, bitSens);
            stepOk := true; // Pour sortir de la boucle de gestion du pas
          end;
          if ((ParametreChauffe.chauffeActive)and(ParametreChauffe.chauffeUtilisateur)) then
          begin
            // Si Chauffe dynamique
            if ParametreChauffe.chauffeDynamique then
//          if true then
            begin
              if not bSignalChauffeHaut then
              begin
                if pulseChauffe>=periodeChauffe then
                begin
                  // Signal de chauffe � 1
                  PortOut(portAdresseBase+2, 4);
                  bSignalChauffeHaut := true;
                end;
              end;

// Appliquer une chauffe fixe m�me si chauffe dynamique coch�e
//            // Chauffe PC mais sans chauffe dynamique
//              if (pulseChauffe=periodeChauffe) then
//              begin
//                // Signal de chauffe � 1
//                PortOut(portAdresseBase+2, 4);
//              end;

              // On met � jour le nouveau periodeChauffe
              periodeChauffe := Trunc(Int(chauffe));
            end else begin
            // Chauffe PC mais sans chauffe dynamique
              if (pulseChauffe=periodeChauffe) then
              begin
                // Signal de chauffe � 1
                PortOut(portAdresseBase+2, 4);
              end;
            end;
            if (pulseChauffe=100) then
            begin
              // Signal de chauffe � 0
              PortOut(portAdresseBase+2, 0);
              pulseChauffe:=0;
              bSignalChauffeHaut := false; // Utilis� que pour la chauffe dynamique
            end;
          end;
        end;
        ancienneHorloge := horloge;
      end;
    end else begin
      // Si on n'a pas de chauffe et donc pas de timer externe
      tempsBas := vitesse - TEMPS_STEP_HAUT;
      if (tempsBas<=0) then tempsBas := TEMPS_STEP_HAUT;
      // Emettre le sens de rotation
      PortOut(portAdresseBase, bitSens);
      for i := 0 to OFFSET_SIGNAL_SENS do
      begin
      end;
      // Emettre l'ordre de rotation + sens
      PortOut(portAdresseBase, bitRotation + bitSens);
      for i := 0 to TEMPS_STEP_HAUT do
      begin
      end;
      // Emettre la remise � zero des bits moteurs
      PortOut(portAdresseBase, bitSens);
      for i := 0 to tempsBas do
      begin
      end;
    end;
  end else begin
    Sleep(-1 * vitesse);
  end;

  Result := codeRetour;
end;

{-----------------------------------------------------------------}
{ Calculer le temps durant lequel le signal de chauffe doit �tre � 1 }
function CalculerTempsSignalHaut(valChauffe : double) : integer;
begin
  Result := 100-Trunc(Int(valChauffe));
end;


{-----------------------------------------------------------------}
{ Initialiser les param�tre de la chauffe chauffe }
procedure InitialiserChauffeEtCommunication(portBase : word ; ParamChauffe : TParametreChauffe ; ParamCommunication : TParametreCommunication ; Materiau : TMateriau);
begin
  portAdresseBase := portBase;
  ParametreChauffe := ParamChauffe;
  ParametreCommunication := ParamCommunication;
  MateriauActif := Materiau;
  // En fait ce n'est pas la p�riode mais le temps ou le signal est � 0
  periodeChauffe := CalculerTempsSignalHaut(MateriauActif.pourcentage1);
  // Compteur d'impulsion de chauffe
  pulseChauffe := 0;
  // Boolean indiquant si le signal de chauffe a �t� plac� au niveau haut
  bSignalChauffeHaut := false;
end;

{-----------------------------------------------------------------}
{ Lire des �tats de la machine                }
{ - Pour l'instant lecture du mode de chauffe 1 mode manuel, 0 mode PC }
function EtatMachine : byte;
var
  lu : byte;
  retour : byte;
begin
  // Mode de chauffe : Lecture du bit 5 registre ADRESSE_BASE+1
  lu := PortIn(portAdresseBase+1);
  lu := lu and $20; // bit 5

  if (lu=$20) then retour := 0
  else retour := 1;

  Result := retour;
end;

{-----------------------------------------------------------------}
{ Adapter les coordonn�es en fonction de la machine }
procedure AdapterOrdres(var ArrayOrdres : TArrayOrdresMoteur);
var
  ArrayTampon : array [0..3] of TOrdreMoteur;
  i, j : integer;
begin
  // Inititalisation du tableau
  for i:=0 to 3 do
  begin
    ArrayTampon[i].bitRotation := 0;
    ArrayTampon[i].bitSens := 0;
  end;
  // Modifier les ordres moteurs
  // Objectif : maintenir les sens de rotation de chaque moteur entre leurs ordres de rotation
  for i:=0 to Length(ArrayOrdres.ArrayOrdres)-1 do
  begin
    // Si on a des mouvements moteur par moteur (pas 2 mouvements moteurs au m�me  instant)
    if (ArrayOrdres.ArrayOrdres[i].bitRotation in [1,2,4,8,16,32,64,128]) then
    begin
      for j := 0 to 3 do
      begin
        // On cherche l'historique du sens moteur i
        if ((ArrayTampon[j].bitRotation = 0)or
            (ArrayTampon[j].bitRotation = ArrayOrdres.ArrayOrdres[i].bitRotation)) then
        begin
          // On recopie le byte moteur
          ArrayTampon[j].bitRotation := ArrayOrdres.ArrayOrdres[i].bitRotation;
          // On change la valeur de l'historique
          ArrayTampon[j].bitSens := ArrayOrdres.ArrayOrdres[i].bitSens;
          break;
        end;
      end;
      // On affecte le sens de rotation en additionnant tous les historiques
      ArrayOrdres.ArrayOrdres[i].bitSens :=
        ArrayTampon[0].bitSens +
        ArrayTampon[1].bitSens +
        ArrayTampon[2].bitSens +
        ArrayTampon[3].bitSens;
    end else begin
      // R�initialisation des historiques suite � un mouvement simutan� de 2 moteurs pour lequel il ne faut pas g�rer d'historique de sens de rotation
      for j := 0 to 3 do
      begin
        ArrayTampon[j].bitRotation := 0;
        ArrayTampon[j].bitSens := 0;
      end;
    end;
  end;

  // Modifier les ordres moteurs pour inclure la gestion de la chauffe
  // chauffe := p�riodeChauffe (comme pour l'init de la chauffe)
  for i:=0 to Length(ArrayOrdres.ArrayOrdres)-1 do
  begin
    ArrayOrdres.ArrayOrdres[i].chauffe := CalculerTempsSignalHaut(ArrayOrdres.ArrayOrdres[i].chauffe);
  end;

  // Optimiser les vitesses de d�placement
  // Fonctionnalit� en BETA, qui semble ne pas fonctionner
  // CompresserOrdresMoteur(ArrayOrdres);
end;

{-----------------------------------------------------------------}
{ Fonction retournant la valeur de la chauffe }
function LireChauffeMachine : double;
var
  ITERATION, timeOut : integer;
  lu : byte;
  periode, nivHaut, nivBas : integer;
  zero : boolean;
begin
  ITERATION := 500000;
  periode := 0;
  zero := false;
  nivHaut := 0;
  nivBas := 0;
  timeOut := 0;
  while ((periode<10)and(timeOut<ITERATION)) do
  begin
    // Contr�le du timeOut
    if (timeOut<ITERATION) then
    begin
      lu := PortIn(portAdresseBase+1);
      lu := lu and $80; // bit 7
//      if (lu div 2)= 0 then
//        lu:=$80;
//      else
//        lu:=0;

      Inc(timeOut);

      if (lu = $80) then
      begin
        Inc(nivHaut);
        if zero then
        begin
          zero := false;
          Inc(periode);
          timeOut := 0; // RAZ du compteur de time out
        end;
      end else begin
        zero := true;
        Inc(nivBas);
      end;
    end;
  end;

  if (periode=0) then
    Result := -1
  else
    Result := nivBas / (nivHaut+nivBas); // nivHaut/(nivHaut+nivBas) donne une chauffe invers�e : chauff max = 0%
end;

{-----------------------------------------------------------------}
{ Compresser les ordres de rotation pour optimiser les vitesses }
procedure CompresserOrdresMoteur(var ArrayOrdres : TArrayOrdresMoteur);
begin

end;

{-----------------------------------------------------------------}
{ New functions to adapt Jedicut capacities (and simplify settings)
{-----------------------------------------------------------------}

{-----------------------------------------------------------------}
{ Enable smooth movement - dependence on EmettreBit function }
{ 0=false | 1=true }
function GetDllAcceptSmoothMove() : smallInt;
begin
  Result := 1;
end;

{-----------------------------------------------------------------}
{ What kind of heating control propose the cnc controller ? }
{ 0=false
  1=true static with pin number
  2=true dynamic with pin number
  3=true static without pin number
  4=true dynamic without pin number
}
function GetDllAcceptHeatingControl() : smallInt;
begin
  Result := 2;
end;

{-----------------------------------------------------------------}
{ Can cnc controller have an external timer in output ? }
{ 0=false | 1=true }
function GetDllSendExternalTimer() : smallInt;
begin
  Result := 1;
end;

{-----------------------------------------------------------------}
{ Does cnc controller have a heating signal in output ? }
{ 0=false | 1=true }
function GetDllSendHeatingSignal() : smallInt;
begin
  Result := 1;
end;

{-----------------------------------------------------------------}
{ Does cnc controller have a heating status signal in output ? }
{ 0=false | 1=true }
function GetDllSendHeatingStatus() : smallInt;
begin
  Result := 1;
end;

{-----------------------------------------------------------------}
{ Does cnc controller need on/off motor signal pin number ? }
{ 0=false | 1=true }
function GetDllAcceptOnOffControl() : smallInt;
begin
  Result := 1;
end;

{-----------------------------------------------------------------}
{ The kind of plugin of communication }
{ DLL_IMG_PARALLEL_PORT = 0
  DLL_IMG_GCODE = 1
  DLL_IMG_ARDUINO = 2
}
function GetDllPicture() : smallInt;
begin
  Result := 0;
end;

end.
