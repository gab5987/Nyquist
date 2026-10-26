%% TPS63030 design calculator
% Preliminary component calculator based on TI TPS63030/TPS63031 datasheet,
% Rev. D (SLVS696D, April 2020).
%
% TI datasheet: https://www.ti.com/lit/ds/symlink/tps63030.pdf

clear; clc;

fprintf('====================================================\n');
fprintf('        TPS63030 preliminary design calculator\n');
fprintf('====================================================\n\n');

%% User inputs (press Enter to accept each default)
Vout = askNum('Desired output voltage Vout (1.2 to 5.5 V)', 3.3);
VinMin = askNum('Minimum input voltage Vin_min (V)', 2.4);
VinMax = askNum('Maximum input voltage Vin_max (V)', 5.0);
Iout = askNum('Maximum required output current (A)', 0.30);
eta = askNum('Estimated efficiency, 0 to 1 (datasheet suggests 0.90 if unknown)', 0.90);
L_uH = askNum('Selected inductance (uH)', 1.5);
R2_kohm = askNum('Choose R2, FB-to-GND (kOhm; TI recommends around 200 kOhm)', 100);
resSeries = askNum('Commercial resistor series: enter 24 for E24 or 96 for E96', 96);

%% Basic validation
if Vout < 1.2 || Vout > 5.5
    error('TPS63030 output range is 1.2 V to 5.5 V. Check the datasheet.');
end
if VinMin < 1.8 || VinMax > 5.5 || VinMin > VinMax
    error('Input range must be within 1.8 V to 5.5 V and Vin_min <= Vin_max.');
end
if VinMin <= 0 || Iout <= 0 || eta <= 0 || eta > 1 || L_uH <= 0 || R2_kohm <= 0
    error('Input values must be positive; efficiency must be in (0,1].');
end
if ~ismember(resSeries,[24 96])
    error('Resistor series must be 24 (E24) or 96 (E96).');
end

%% Feedback divider
Vfb = 0.500;                  % Typical FB reference, V
R2 = R2_kohm * 1e3;           % ohms
R1_ideal = R2 * (Vout/Vfb - 1);

% Generate preferred-value resistor series over decades and select nearest.
if resSeries == 24
    base = [10 11 12 13 15 16 18 20 22 24 27 30 33 36 39 43 47 51 56 62 68 75 82 91];
else
    base = [100 102 105 107 110 113 115 118 121 124 127 130 133 137 140 143 ...
            147 150 154 158 162 165 169 174 178 182 187 191 196 200 205 210 ...
            215 221 226 232 237 243 249 255 261 267 274 280 287 294 301 309 ...
            316 324 332 340 348 357 365 374 383 392 402 412 422 432 442 453 ...
            464 475 487 499 511 523 536 549 562 576 590 604 619 634 649 665 ...
            681 698 715 732 750 768 787 806 825 845 866 887 909 931 953 976];
end
candidate = [];
for decade = -1:7
    candidate = [candidate, base * 10^decade]; %#ok<AGROW>
end
[~, idx] = min(abs(candidate - R1_ideal));
R1 = candidate(idx);
Vout_actual = Vfb * (1 + R1/R2);
dividerCurrent = Vfb/R2;
P_R1 = (Vout_actual - Vfb)^2/R1;
P_R2 = Vfb^2/R2;

%% Inductor peak-current estimate in BOOST mode
% TI equation (boost mode): Ipeak = Iout/[eta*(1-D)] + Vin*D/(2*L*f)
% D = (Vout - Vin)/Vout. Use the minimum input voltage in boost mode.
% Datasheet typical switching frequency is 2.5 MHz.
fsw = 2.5e6;
if VinMin < Vout
    VinBoost = VinMin;
    D = (Vout - VinBoost)/Vout;
    IpeakBoost = Iout/(eta*(1-D)) + VinBoost*D/(2*(L_uH*1e-6)*fsw);
    IavgBoost = Iout/(eta*(1-D));
else
    D = 0;
    IpeakBoost = NaN;
    IavgBoost = NaN;
end
IsatRecommended = 1.20 * IpeakBoost;

%% Capacitors: datasheet recommended starting values
Cin_recommended_uF = 4.7;  % at least 4.7 uF, close to VIN and PGND
Cvina_recommended_uF = 0.1; % must not exceed 0.22 uF
Cout_recommended_uF = 10;  % recommended nominal output capacitance

%% Print report
fprintf('\n================ DESIGN RESULTS ================\n');
fprintf('Output target:             %.3f V\n', Vout);
fprintf('Input range:               %.3f V to %.3f V\n', VinMin, VinMax);
fprintf('Maximum load current:      %.3f A\n', Iout);
fprintf('Efficiency assumption:     %.1f %%\n', eta*100);

fprintf('\n--- Feedback divider (datasheet section 9.2.2.1) ---\n');
fprintf('R2 (FB to GND):             %.3f kOhm\n', R2/1e3);
fprintf('Ideal R1 (VOUT to FB):      %.3f kOhm\n', R1_ideal/1e3);
fprintf('Selected E%d R1:            %.3f kOhm\n', resSeries, R1/1e3);
fprintf('Calculated nominal Vout:    %.4f V\n', Vout_actual);
fprintf('Nominal error:              %+.3f %%\n', 100*(Vout_actual/Vout - 1));
fprintf('Divider current at FB=0.5V: %.3f uA\n', dividerCurrent*1e6);
fprintf('R1 dissipation:              %.4f mW\n', P_R1*1e3);
fprintf('R2 dissipation:              %.4f mW\n', P_R2*1e3);
fprintf('Note: resistor tolerance and FB-reference tolerance affect actual Vout.\n');

fprintf('\n--- Inductor estimate (datasheet section 9.2.2.2) ---\n');
fprintf('Selected inductance:         %.3f uH\n', L_uH);
fprintf('Switching frequency used:    %.2f MHz (typical)\n', fsw/1e6);
if ~isnan(IpeakBoost)
    fprintf('Boost duty estimate at Vin_min: %.2f %%\n', D*100);
    fprintf('Average inductor/input current estimate: %.3f A\n', IavgBoost);
    fprintf('Estimated peak inductor current: %.3f A\n', IpeakBoost);
    fprintf('Suggested inductor Isat >= 1.2*Ipeak: %.3f A\n', IsatRecommended);
    if IpeakBoost >= 1.0
        fprintf('WARNING: Estimated peak current is near/above the typical 1-A switch-current limit.\n');
    else
        fprintf('Current estimate is below 1 A, but verify all operating points and limits in the datasheet.\n');
    end
else
    fprintf('Vin_min >= Vout: boost-mode peak-current equation not evaluated for this input range.\n');
    fprintf('Check buck-mode current using the datasheet equations and application conditions.\n');
end
fprintf('This estimate is not a guarantee of output-current capability.\n');

fprintf('\n--- Recommended capacitor starting values (section 9.2.2.3) ---\n');
fprintf('Input capacitor Cin:        >= %.1f uF ceramic, close to VIN/PGND\n', Cin_recommended_uF);
fprintf('VINA bypass capacitor:       %.1f uF ceramic, close to VINA/GND (max 0.22 uF)\n', Cvina_recommended_uF);
fprintf('Output capacitor Cout:      %.1f uF ceramic, close to VOUT/PGND\n', Cout_recommended_uF);
fprintf('Check effective capacitance after DC-bias derating and capacitor voltage rating.\n');

%% Local helper: numeric input with default
function value = askNum(prompt, defaultValue)
    s = input(sprintf('%s [default %.4g]: ', prompt, defaultValue), 's');
    if isempty(strtrim(s))
        value = defaultValue;
    else
        value = str2double(s);
        if isnan(value) || ~isfinite(value)
            error('Invalid numeric input for: %s', prompt);
        end
    end
end