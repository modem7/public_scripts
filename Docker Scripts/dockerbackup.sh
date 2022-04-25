#/bin/sh
##Variables
SOURCEFOLDER=/home/alex/DockerApps #to backup non-docker volumes
DESTINATION=/var/hda/files/drives/drive12/downloads/Backups/dockerbackup/DockerApps.tar.gz #location where tar file will be saved to

##Backup
sudo docker pull loomchild/volume-backup ; \ #docker volume backup tool
sudo docker container stop $(sudo docker container ls -aq) ; \ #stop all containers
#sudo docker run -v hda_NZBHydra2:/volume --rm loomchild/volume-backup backup -v - > /var/hda/files/drives/drive12/downloads/Backups/dockerbackup/hda_NZBHydra2.tar.bz2 ; \
#sudo docker run -v hda_Radarr:/volume --rm loomchild/volume-backup backup -v - > /var/hda/files/drives/drive12/downloads/Backups/dockerbackup/hda_Radarr.tar.bz2 ; \
#sudo docker run -v hda_SABNZBD:/volume --rm loomchild/volume-backup backup -v - > /var/hda/files/drives/drive12/downloads/Backups/dockerbackup/hda_SABNZBD.tar.bz2 ; \
#sudo docker run -v hda_Sonarrv3:/volume --rm loomchild/volume-backup backup -v - > /var/hda/files/drives/drive12/downloads/Backups/dockerbackup/hda_Sonarrv3.tar.bz2 ; \
#sudo docker run -v hda_Ombi:/volume --rm loomchild/volume-backup backup -v - > /var/hda/files/drives/drive12/downloads/Backups/dockerbackup/hda_Ombi.tar.bz2 ; \
#sudo docker run -v hda_Tautulli:/volume --rm loomchild/volume-backup backup -v - > /var/hda/files/drives/drive12/downloads/Backups/dockerbackup/hda_Tautulli.tar.bz2 ; \
#sudo docker run -v hda_DDClient:/volume --rm loomchild/volume-backup backup -v - > /var/hda/files/drives/drive12/downloads/Backups/dockerbackup/hda_DDClient.tar.bz2 ; \
#sudo docker run -v hda_DNSCrypt:/volume --rm loomchild/volume-backup backup -v - > /var/hda/files/drives/drive12/downloads/Backups/dockerbackup/hda_DNSCrypt.tar.bz2 ; \
sudo docker run -v hda_Dnsmasq:/volume --rm loomchild/volume-backup backup -v - > /var/hda/files/drives/drive12/downloads/Backups/dockerbackup/hda_Dnsmasq.tar.bz2 ; \
sudo docker run -v hda_Pihole:/volume --rm loomchild/volume-backup backup -v - > /var/hda/files/drives/drive12/downloads/Backups/dockerbackup/hda_Pihole.tar.bz2 ; \
#sudo docker run -v hda_Letsencrypt:/volume --rm loomchild/volume-backup backup -v - > /var/hda/files/drives/drive12/downloads/Backups/dockerbackup/hda_Letsencrypt.tar.bz2 ; \
#sudo docker run -v hda_NginxConfig:/volume --rm loomchild/volume-backup backup -v - > /var/hda/files/drives/drive12/downloads/Backups/dockerbackup/hda_NginxConfig.tar.bz2 ; \
#sudo docker run -v hda_NginxData:/volume --rm loomchild/volume-backup backup -v - > /var/hda/files/drives/drive12/downloads/Backups/dockerbackup/hda_NginxData.tar.bz2 ; \
#sudo docker run -v hda_NginxDB:/volume --rm loomchild/volume-backup backup -v - > /var/hda/files/drives/drive12/downloads/Backups/dockerbackup/hda_NginxDB.tar.bz2 ; \
#sudo docker run -v hda_Xwiki-Data:/volume --rm loomchild/volume-backup backup -v - > /var/hda/files/drives/drive12/downloads/Backups/dockerbackup/hda_Xwiki-Data.tar.bz2 ; \
#sudo docker run -v hda_Xwiki-DB:/volume --rm loomchild/volume-backup backup -v - > /var/hda/files/drives/drive12/downloads/Backups/dockerbackup/hda_Xwiki-DB.tar.bz2 ; \

tar -cpzf $DESTINATION $SOURCEFOLDER ; \ #create the backup

sudo docker container start $(sudo docker container ls -aq) ; \ #start all containers
sudo docker container stop Guacamole ; \ #stop guacamole to save resouces
sudo docker rmi loomchild/volume-backup; #delete volume backup tool image

