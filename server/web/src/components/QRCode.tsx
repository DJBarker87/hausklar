import QRCodeEncoder from "qrcode";
import { useEffect, useState } from "react";

export function QRCode({ value, label, size = 220 }: { value: string; label: string; size?: number }) {
  const [source, setSource] = useState<string | null>(null);

  useEffect(() => {
    let active = true;
    void QRCodeEncoder.toDataURL(value, {
      width: size,
      margin: 2,
      errorCorrectionLevel: "M",
      color: { dark: "#17231d", light: "#ffffff" },
    }).then((url) => { if (active) setSource(url); });
    return () => { active = false; };
  }, [size, value]);

  return source ? <img className="hausklar-qr" src={source} width={size} height={size} alt={label} /> : <div className="hausklar-qr-placeholder" aria-label={`Preparing ${label}`} />;
}
