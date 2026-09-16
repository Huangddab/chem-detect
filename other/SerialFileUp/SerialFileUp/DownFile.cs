using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.IO;
using System.IO.Ports;
using System.Threading;
using System.Windows.Forms;

namespace SerialFileUp
{
    public  unsafe static class DownFile
    {
        public static int DownState = 0;
        private static SerialPort ComPort;
        private static byte[] PackHeadBytes = new byte[12] { 0x3a, 0xa1, 0xbb, 0x44, 0x7f, 0xff, 0xfe, 0x00, 0x00, 0x00, 0x00, 0x00 };
        private static byte[] GetPackHead(int PackId, int DataSize, int crc)
        {
            if (crc == 1) DataSize += 2;
            if (crc == 10) DataSize += 4;
            PackHeadBytes[7] = (byte)crc;
            PackHeadBytes[8] = (byte)PackId;
            PackHeadBytes[9] = (byte)(PackId >> 8);
            PackHeadBytes[10] = (byte)DataSize;
            PackHeadBytes[11] = (byte)(DataSize >> 8);
            return PackHeadBytes;
        }
        private static byte[] GetCRC(byte[] data, int crc)
        {
            byte[] crcbt=new byte[0];
            uint crcval = 0;
            fixed (void* p = data)
            {
                if (crc == 1)
                {
                    crcval = CRCSOFT.CRC16_MODBUS((byte*)p, data.Length);
                    crcbt = new byte[2];
                    crcbt[0] = (byte)crcval;
                    crcbt[1] = (byte)(crcval >> 8);
                }
                else if (crc == 10)
                {
                    crcval = CRCSOFT.CRC32(0xffffffff, (byte*)p, data.Length);
                    crcbt = new byte[4];
                    crcbt[0] = (byte)crcval;
                    crcbt[1] = (byte)(crcval >> 8);
                    crcbt[2] = (byte)(crcval >> 16);
                    crcbt[3] = (byte)(crcval >> 24);
                }
            }
            return crcbt;
        }
        private static void ComPort_SendString(string str, Encoding en)
        {
            try
            {
                if (ComPort.IsOpen != true) return;
                byte[] endbytes = new byte[3] { 255, 255, 255 };
                byte[] bt1 = en.GetBytes(str);
                ComPort.Write(bt1, 0, bt1.Length);
                ComPort.Write(endbytes, 0, endbytes.Length);
            }
            catch (Exception ex)
            {
                MessageBoxForm.MsgBox("Error", ex.Message, "");
            }
        }
        private static void ComPort_Clear()
        {
            byte[] bt = new byte[ComPort.BytesToRead];
            ComPort.Read(bt, 0, bt.Length);
        }
        private static byte[] ComPort_ReadByte(int minsize, int outtime)
        {
            if (ComPort.IsOpen != true) return new byte[0];
            byte[] bt = new byte[128000];
            int index = 0;
            while (outtime > 0)
            {
                int rsize = ComPort.BytesToRead;
                ComPort.Read(bt, index, rsize);
                index += rsize;
                outtime -= 20;
                if (index >= minsize) break;
                Application.DoEvents();
                Thread.Sleep(20);
            }
            byte[] newbt = new byte[index];
            for (int i = 0; i < index; i++)
            {
                newbt[i] = bt[i];
            }
            return newbt;
        }
        public static bool DownLoad(SerialPort ComPort_, ProgressBar progressBar, TextBox textBox1, string FilePath, string DecPath, int crc, int PackDataSize)
        {
            int retry = 0;
            DownState = 1;
            ComPort = ComPort_;
            StreamReader sr = null;
            try
            {
                int PackId = 0;
                byte[] bt1;
                sr = new StreamReader(FilePath);
                int AllSize = (int)sr.BaseStream.Length;
                int rsize = PackDataSize;
                progressBar.Minimum = 0;
                progressBar.Value = 0;
                progressBar.Maximum = AllSize;
                //Step 1: send a transmission command 
                //第一步：发送透传命令
                while (DownState == 1)
                {
                    Application.DoEvents();
                    ComPort.Write(new byte[4] { 0, 255, 255, 255 }, 0, 4);//发一条空指令
                    ComPort_Clear(); //Empty Accept Buffer  清空接受缓冲
                    ComPort_SendString("twfile \"" + DecPath + "\"," + AllSize.ToString(), Encoding.UTF8);
                    bt1 = ComPort_ReadByte(4, 1000);
                    if (bt1.Length == 4 && bt1[0] == 0xfe) break;
                    //The correct start transmission response cannot be received, or the screen may have entered transmission mode, only because the interference did not receive the correct response, so it is necessary to send an exit transmission package at this time
                    //收不到正确的开始透传回应，也有可能屏幕已经进入透传模式，只是因为干扰没有收到正确回应，因此此时需要发一次退出透传包
                    Thread.Sleep(30); //30ms delay must be recognized as an exit package by the screen 30ms延时后一定能被屏幕识别为退出包
                    bt1 = GetPackHead(65535, 0, 0);
                    ComPort.Write(bt1, 0, bt1.Length);//Send exit packet 发送退出包
                    Thread.Sleep(60);//Wait for screen response 等待屏幕反应
                    ComPort.Write(new byte[4] { 0, 255, 255, 255 }, 0, 4);//发一条空指令; //Send an invalid instruction to ensure that the correct command is received next time 发送一条无效指令确保下次能收到正确指令
                    Thread.Sleep(60);//Wait for screen response 等待屏幕反应
                    retry++;
                    if (retry > 3)
                    {
                        textBox1.AppendText("Send File Error: " + FilePath + "\r\n");
                        DownState = 0;
                    }
                }
                //At this time has entered the transmission state, can begin to transmit the data
                //此时已经进入透传状态，可以开始透传数据了
                retry = 0;
                int i = 0;
                while (AllSize > 0 && DownState == 1)
                {
                    i++;
                    Application.DoEvents();
                    ComPort_Clear(); //Empty Accept Buffer  清空接受缓冲
                    if (AllSize < rsize) rsize = AllSize;
                    bt1 = GetPackHead(PackId, rsize, crc);
                    ComPort.Write(bt1, 0, bt1.Length);//Sending packet header  发送包头
                    bt1 = new byte[rsize];
                    sr.BaseStream.Read(bt1, 0, bt1.Length);
                    ComPort.Write(bt1, 0, bt1.Length);// send data 发送数据
                    if (crc != 0)//With crc  有crc
                    {
                        bt1 = GetCRC(bt1, crc);
                        ComPort.Write(bt1, 0, bt1.Length);//Send crc 发送crc
                    }
                    bt1 = ComPort_ReadByte(AllSize == rsize ? 4 : 1, 1000);
                    if (bt1.Length == 1 && bt1[0] == 5)
                    {
                        textBox1.AppendText("Send Packet SUC:" + PackId.ToString() + "\r\n");
                        PackId++;
                        AllSize -= rsize;
                        progressBar.Value += rsize;
                        retry = 0;
                    }
                    else if (bt1.Length == 4 && bt1[0] == 0xfd)
                    {
                        progressBar.Value += rsize;
                        textBox1.AppendText("File Send SUC:" + FilePath + "\r\n");
                        break;
                    }
                    else
                    {
                        sr.BaseStream.Position -= rsize;
                        Thread.Sleep(30);//Pause 30ms each time you re-send a packet  每次重发上一包停顿30ms
                        textBox1.AppendText("Send Data Error: PackID:" + PackId.ToString() + "\r\n");
                        retry++;
                        if (retry >= 10)
                        {
                            textBox1.AppendText("Send File Error: " + FilePath + "\r\n");
                            DownState = 0;
                        }
                    }
                }
                if (DownState == 0)
                {
                    progressBar.Minimum = 0;
                    progressBar.Value = 0;
                    progressBar.Maximum = 0;
                }

                sr.Close();
                sr.Dispose();
                sr = null;
                if (DownState == 0)
                {
                    Thread.Sleep(30);//Pause 30ms each time you re-send a packet 每次重发上一包停顿30ms
                    bt1 = GetPackHead(65535, 0, 0);
                    ComPort.Write(bt1, 0, bt1.Length);//Send exit packet  发送退出包
                }
                return true; ;
            }
            catch (Exception ex)
            {
                MessageBoxForm.MsgBox("Error", ex.Message, "");
                if (sr != null)
                {
                    sr.Close();
                    sr.Dispose();
                }
            }
            return false;
        }

    }
}
